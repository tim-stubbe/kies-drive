from __future__ import annotations

import json
import os
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import httpx
import pyotp
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, Response
from pydantic import BaseModel

from .auth import (PASSWORD_HASHER, authenticated_user, create_session, create_verification,
                   initialise_auth_schema, normalise_email, send_verification_email,
                   totp_matches, utcnow, validate_password, verification_html,
                   verify_email_token, verify_password)

app = FastAPI(title="Kies Drive", version="1.0.0")
KIES_BASE_URL = os.getenv("KIES_BASE_URL", "https://100.72.226.91:8000").rstrip("/")


def db() -> sqlite3.Connection:
    db_path = Path(os.getenv("KIES_DRIVE_DB", "/data/kies-drive.db"))
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.executescript("""
      CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL, updated_at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS commands (id INTEGER PRIMARY KEY AUTOINCREMENT, command TEXT NOT NULL, arguments TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', result TEXT, created_at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS user_state (user_id INTEGER PRIMARY KEY, payload TEXT NOT NULL, updated_at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS user_commands (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, command TEXT NOT NULL, arguments TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', result TEXT, created_at TEXT NOT NULL);
    """)
    initialise_auth_schema(conn)
    return conn


class RegisterRequest(BaseModel):
    email: str
    password: str


class LoginRequest(BaseModel):
    email: str
    password: str
    totp_code: Optional[str] = None


class TOTPRequest(BaseModel):
    code: str


AUTH_ATTEMPTS: dict[str, list[float]] = {}


def rate_limit(key: str, maximum: int = 8, window: int = 900) -> None:
    now = time.monotonic()
    recent = [value for value in AUTH_ATTEMPTS.get(key, []) if now - value < window]
    if len(recent) >= maximum:
        raise HTTPException(429, "Zu viele Versuche. Bitte warte einen Moment.")
    recent.append(now)
    AUTH_ATTEMPTS[key] = recent


def current_user(authorization: str | None) -> sqlite3.Row:
    with db() as conn:
        return authenticated_user(conn, authorization)


@app.get("/healthz")
def healthz():
    return {"ok": True, "service": "kies-drive"}


@app.post("/auth/register", status_code=202)
def register(payload: RegisterRequest, request: Request):
    email = normalise_email(payload.email)
    validate_password(payload.password)
    rate_limit(f"register:{request.client.host if request.client else 'unknown'}", maximum=5, window=3600)
    with db() as conn:
        existing = conn.execute("SELECT id,email_verified_at FROM users WHERE email=?", (email,)).fetchone()
        if existing and existing["email_verified_at"]:
            return {"ok": True, "message": "Falls möglich, wurde eine E-Mail versendet."}
        if existing:
            user_id = existing["id"]
            conn.execute("UPDATE users SET password_hash=? WHERE id=?", (PASSWORD_HASHER.hash(payload.password), user_id))
        else:
            cursor = conn.execute(
                "INSERT INTO users(email,password_hash,created_at) VALUES(?,?,?)",
                (email, PASSWORD_HASHER.hash(payload.password), utcnow().isoformat()),
            )
            user_id = cursor.lastrowid
        raw = create_verification(conn, user_id)
    try:
        send_verification_email(email, raw)
    except RuntimeError as exc:
        raise HTTPException(503, str(exc)) from exc
    return {"ok": True, "message": "Bitte bestätige deine E-Mail-Adresse."}


@app.get("/auth/verify-email", response_class=HTMLResponse)
def verify_email(token: str):
    with db() as conn:
        ok = verify_email_token(conn, token)
    return HTMLResponse(verification_html(ok), status_code=200 if ok else 400)


@app.post("/auth/login")
def login(payload: LoginRequest, request: Request):
    email = normalise_email(payload.email)
    key = f"login:{request.client.host if request.client else 'unknown'}:{email}"
    rate_limit(key)
    with db() as conn:
        user = conn.execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()
        if not user or not verify_password(user["password_hash"], payload.password):
            raise HTTPException(401, "E-Mail-Adresse oder Passwort ist falsch.")
        if not user["email_verified_at"]:
            raise HTTPException(403, "Bitte bestätige zuerst deine E-Mail-Adresse.")
        if user["totp_secret"] and (not payload.totp_code or not totp_matches(user["totp_secret"], payload.totp_code)):
            raise HTTPException(401, "Der Authenticator-Code fehlt oder ist ungültig.")
        raw, expires_at = create_session(conn, user["id"])
    AUTH_ATTEMPTS.pop(key, None)
    return {"session": raw, "expires_at": expires_at, "email": email,
            "two_factor_enabled": bool(user["totp_secret"])}


@app.get("/auth/me")
def me(authorization: str | None = Header(None)):
    user = current_user(authorization)
    return {"email": user["email"], "email_verified": bool(user["email_verified_at"]),
            "two_factor_enabled": bool(user["totp_secret"])}


@app.post("/auth/logout")
def logout(authorization: str | None = Header(None)):
    with db() as conn:
        user = authenticated_user(conn, authorization)
        conn.execute("UPDATE sessions SET revoked_at=? WHERE id=?", (utcnow().isoformat(), user["session_id"]))
    return {"ok": True}


@app.post("/auth/2fa/setup")
def setup_2fa(authorization: str | None = Header(None)):
    user = current_user(authorization)
    secret = pyotp.random_base32()
    with db() as conn:
        conn.execute("UPDATE users SET totp_pending_secret=? WHERE id=?", (secret, user["id"]))
    uri = pyotp.TOTP(secret).provisioning_uri(name=user["email"], issuer_name="Kies Drive")
    return {"secret": secret, "provisioning_uri": uri}


@app.post("/auth/2fa/enable")
def enable_2fa(payload: TOTPRequest, authorization: str | None = Header(None)):
    user = current_user(authorization)
    pending = user["totp_pending_secret"] or ""
    if not pending or not totp_matches(pending, payload.code):
        raise HTTPException(422, "Der Authenticator-Code ist ungültig.")
    with db() as conn:
        conn.execute("UPDATE users SET totp_secret=?,totp_pending_secret=NULL WHERE id=?", (pending, user["id"]))
    return {"ok": True}


@app.put("/api/navigation/remote/state")
async def put_state(request: Request, authorization: str | None = Header(None)):
    user = current_user(authorization)
    payload = await request.json()
    with db() as conn:
        conn.execute("INSERT INTO user_state(user_id,payload,updated_at) VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET payload=excluded.payload, updated_at=excluded.updated_at",
                     (user["id"], json.dumps(payload), datetime.now(timezone.utc).isoformat()))
    return {"ok": True}


@app.get("/api/navigation/remote/commands")
def commands(authorization: str | None = Header(None)):
    user = current_user(authorization)
    with db() as conn:
        rows = conn.execute("SELECT id,command,arguments FROM user_commands WHERE user_id=? AND status='pending' ORDER BY id", (user["id"],)).fetchall()
    return {"commands": [{"id": r["id"], "command": r["command"], "arguments": json.loads(r["arguments"])} for r in rows]}


@app.post("/api/navigation/remote/commands/{command_id}/complete")
async def complete(command_id: int, request: Request, authorization: str | None = Header(None)):
    user = current_user(authorization)
    payload = await request.json()
    with db() as conn:
        conn.execute("UPDATE user_commands SET status=?, result=? WHERE id=? AND user_id=?", ("done" if payload.get("ok") else "failed", json.dumps(payload), command_id, user["id"]))
    return {"ok": True}


EMPTY_SCHEMA = {"type": "object", "properties": {}, "additionalProperties": False}
TOOLS = [
    {"name": "get_location", "description": "Aktuellen Standort lesen", "inputSchema": EMPTY_SCHEMA},
    {"name": "get_heading", "description": "Fahrtrichtung lesen", "inputSchema": EMPTY_SCHEMA},
    {"name": "get_speed", "description": "Geschwindigkeit lesen", "inputSchema": EMPTY_SCHEMA},
    {"name": "get_active_route", "description": "Aktive Route und Trip-Lock lesen", "inputSchema": EMPTY_SCHEMA},
    {"name": "get_next_maneuver", "description": "Nächsten Navigationsschritt lesen", "inputSchema": EMPTY_SCHEMA},
    {"name": "restore_route", "description": "Persistente Route wiederherstellen", "inputSchema": EMPTY_SCHEMA},
    {"name": "add_route_stop", "description": "POI mit geringem Umweg als Zwischenstopp hinzufügen", "inputSchema": {
        "type": "object", "properties": {"query": {"type": "string", "minLength": 2}},
        "required": ["query"], "additionalProperties": False}},
    {"name": "set_route_options", "description": "Routenvorgaben ändern", "inputSchema": {
        "type": "object", "properties": {
            "waypoint_id": {"type": "string"}, "avoid_tolls": {"type": "boolean"},
            "avoid_highways": {"type": "boolean"}}, "additionalProperties": False}},
    {"name": "set_destination", "description": "Ziel und Pflichtpunkte setzen", "inputSchema": {
        "type": "object", "properties": {
            "query": {"type": "string"}, "latitude": {"type": "number", "minimum": -90, "maximum": 90},
            "longitude": {"type": "number", "minimum": -180, "maximum": 180},
            "required_waypoints": {"type": "array", "items": {"type": "object"}}},
        "additionalProperties": False}},
]


@app.post("/mcp")
async def mcp(request: Request, authorization: str | None = Header(None)):
    user = current_user(authorization)
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
            if isinstance(name, str) and name.startswith("get_"):
                row = conn.execute("SELECT payload,updated_at FROM user_state WHERE user_id=?", (user["id"],)).fetchone()
                state = json.loads(row["payload"]) if row else {}
                keys = {"get_location":"location", "get_heading":"heading_degrees", "get_speed":"speed_kmh", "get_next_maneuver":"next_maneuver"}
                value = {"active_route": state.get("active_route"), "route_lock": state.get("route_lock")} if name == "get_active_route" else state.get(keys.get(name, ""))
                updated_at = datetime.fromisoformat(row["updated_at"]) if row else None
                age = max(0, (datetime.now(timezone.utc) - updated_at).total_seconds()) if updated_at else None
                data = {"value": value, "updated_at": row["updated_at"] if row else None,
                        "age_seconds": age, "live": age is not None and age <= 30}
            elif name in {"set_destination", "set_route_options", "restore_route", "add_route_stop"}:
                cur = conn.execute("INSERT INTO user_commands(user_id,command,arguments,created_at) VALUES(?,?,?,?)",
                                   (user["id"], name, json.dumps(args), datetime.now(timezone.utc).isoformat()))
                data = {"accepted": True, "command_id": cur.lastrowid}
            else:
                raise HTTPException(400, "Unbekanntes Tool")
        result = {"content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False)}]}
    else:
        return {"jsonrpc": "2.0", "id": rpc_id, "error": {"code": -32601, "message": "Method not found"}}
    return {"jsonrpc": "2.0", "id": rpc_id, "result": result}


@app.api_route("/api/navigation/{path:path}", methods=["GET", "POST"])
async def kies_proxy(path: str, request: Request, authorization: str | None = Header(None)):
    # Navigation data that still belongs to Kies (fuel, toll/search, Jarvis) is
    # consumed through this narrow authenticated proxy.
    current_user(authorization)
    headers = {"X-Kies-Device-Token": os.getenv("KIES_DEVICE_TOKEN", "")}
    async with httpx.AsyncClient(verify=False, timeout=30) as client:
        upstream = await client.request(request.method, f"{KIES_BASE_URL}/api/navigation/{path}", params=request.query_params,
                                        content=await request.body(), headers=headers)
    return Response(upstream.content, status_code=upstream.status_code, media_type=upstream.headers.get("content-type"))


@app.post("/api/jarvis/chat")
async def jarvis_proxy(request: Request, authorization: str | None = Header(None)):
    """Keep the existing assistant integration while Kies Drive is deployed separately."""
    current_user(authorization)
    headers = {"X-Kies-Device-Token": os.getenv("KIES_DEVICE_TOKEN", "")}
    async with httpx.AsyncClient(verify=False, timeout=30) as client:
        upstream = await client.post(
            f"{KIES_BASE_URL}/api/jarvis/chat",
            content=await request.body(),
            headers=headers,
        )
    return Response(upstream.content, status_code=upstream.status_code, media_type=upstream.headers.get("content-type"))
