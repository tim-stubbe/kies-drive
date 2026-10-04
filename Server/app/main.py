import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import Response

app = FastAPI(title="Kies Drive", version="1.0.0")
DB_PATH = Path(os.getenv("KIES_DRIVE_DB", "/data/kies-drive.db"))
KIES_BASE_URL = os.getenv("KIES_BASE_URL", "https://100.72.226.91:8000").rstrip("/")


def db() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.executescript("""
      CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL, updated_at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS commands (id INTEGER PRIMARY KEY AUTOINCREMENT, command TEXT NOT NULL, arguments TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', result TEXT, created_at TEXT NOT NULL);
    """)
    return conn


def bearer(value: str | None, expected_name: str) -> None:
    expected = os.getenv(expected_name, "").strip()
    if not expected:
        raise HTTPException(503, f"{expected_name} ist nicht gesetzt")
    if value != f"Bearer {expected}":
        raise HTTPException(401, "Ungültiger Token")


def device(value: str | None) -> None:
    expected = os.getenv("KIES_DRIVE_DEVICE_TOKEN", "").strip()
    if not expected or value != expected:
        raise HTTPException(401, "Ungültiger Geräte-Token")


@app.get("/healthz")
def healthz():
    return {"ok": True, "service": "kies-drive"}


@app.put("/api/navigation/remote/state")
async def put_state(request: Request, x_kies_device_token: str | None = Header(None)):
    device(x_kies_device_token)
    payload = await request.json()
    with db() as conn:
        conn.execute("INSERT INTO state(id,payload,updated_at) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, updated_at=excluded.updated_at",
                     (json.dumps(payload), datetime.now(timezone.utc).isoformat()))
    return {"ok": True}


@app.get("/api/navigation/remote/commands")
def commands(x_kies_device_token: str | None = Header(None)):
    device(x_kies_device_token)
    with db() as conn:
        rows = conn.execute("SELECT id,command,arguments FROM commands WHERE status='pending' ORDER BY id").fetchall()
    return {"commands": [{"id": r["id"], "command": r["command"], "arguments": json.loads(r["arguments"])} for r in rows]}


@app.post("/api/navigation/remote/commands/{command_id}/complete")
async def complete(command_id: int, request: Request, x_kies_device_token: str | None = Header(None)):
    device(x_kies_device_token)
    payload = await request.json()
    with db() as conn:
        conn.execute("UPDATE commands SET status=?, result=? WHERE id=?", ("done" if payload.get("ok") else "failed", json.dumps(payload), command_id))
    return {"ok": True}


TOOLS = [
    {"name": n, "description": d, "inputSchema": {"type": "object", "additionalProperties": True}}
    for n, d in [
        ("get_location", "Aktuellen Standort lesen"), ("get_heading", "Fahrtrichtung lesen"),
        ("get_speed", "Geschwindigkeit lesen"), ("get_active_route", "Aktive Route und Trip-Lock lesen"),
        ("get_next_maneuver", "Nächsten Navigationsschritt lesen"), ("set_destination", "Ziel und Pflichtpunkte setzen"),
        ("set_route_options", "Routenvorgaben ändern"), ("restore_route", "Persistente Route wiederherstellen"),
    ]
]


@app.post("/mcp")
async def mcp(request: Request, authorization: str | None = Header(None)):
    bearer(authorization, "KIES_DRIVE_MCP_TOKEN")
    body = await request.json()
    method, params, rpc_id = body.get("method"), body.get("params") or {}, body.get("id")
    if method == "initialize":
        result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "kies-drive", "version": "1.0.0"}}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        with db() as conn:
            if name.startswith("get_"):
                row = conn.execute("SELECT payload,updated_at FROM state WHERE id=1").fetchone()
                state = json.loads(row["payload"]) if row else {}
                keys = {"get_location":"location", "get_heading":"heading_degrees", "get_speed":"speed_kmh", "get_next_maneuver":"next_maneuver"}
                value = {"active_route": state.get("active_route"), "route_lock": state.get("route_lock")} if name == "get_active_route" else state.get(keys.get(name, ""))
                data = {"value": value, "updated_at": row["updated_at"] if row else None}
            elif name in {"set_destination", "set_route_options", "restore_route"}:
                cur = conn.execute("INSERT INTO commands(command,arguments,created_at) VALUES(?,?,?)", (name, json.dumps(args), datetime.now(timezone.utc).isoformat()))
                data = {"accepted": True, "command_id": cur.lastrowid}
            else:
                raise HTTPException(400, "Unbekanntes Tool")
        result = {"content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False)}]}
    else:
        return {"jsonrpc": "2.0", "id": rpc_id, "error": {"code": -32601, "message": "Method not found"}}
    return {"jsonrpc": "2.0", "id": rpc_id, "result": result}


@app.api_route("/api/navigation/{path:path}", methods=["GET", "POST"])
async def kies_proxy(path: str, request: Request, x_kies_device_token: str | None = Header(None)):
    # Navigation data that still belongs to Kies (fuel, toll/search, Jarvis) is
    # consumed through this narrow authenticated proxy.
    headers = {"X-Kies-Device-Token": os.getenv("KIES_DEVICE_TOKEN", x_kies_device_token or "")}
    async with httpx.AsyncClient(verify=False, timeout=30) as client:
        upstream = await client.request(request.method, f"{KIES_BASE_URL}/api/navigation/{path}", params=request.query_params,
                                        content=await request.body(), headers=headers)
    return Response(upstream.content, status_code=upstream.status_code, media_type=upstream.headers.get("content-type"))


@app.post("/api/jarvis/chat")
async def jarvis_proxy(request: Request, x_kies_device_token: str | None = Header(None)):
    """Keep the existing assistant integration while Kies Drive is deployed separately."""
    headers = {"X-Kies-Device-Token": os.getenv("KIES_DEVICE_TOKEN", x_kies_device_token or "")}
    async with httpx.AsyncClient(verify=False, timeout=30) as client:
        upstream = await client.post(
            f"{KIES_BASE_URL}/api/jarvis/chat",
            content=await request.body(),
            headers=headers,
        )
    return Response(upstream.content, status_code=upstream.status_code, media_type=upstream.headers.get("content-type"))
