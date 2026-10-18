from __future__ import annotations

import json
import os
import re
import base64
import hashlib
import secrets
import sqlite3
import time
from html import escape
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any, Optional
from urllib.parse import parse_qs, urlencode, urlparse

import httpx
import pyotp
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from pydantic import BaseModel

from .auth import (PASSWORD_HASHER, authenticated_user, complete_registration,
                   consume_password_reset, create_password_reset,
                   consume_recovery_code, create_recovery_codes, create_session, create_verification,
                   create_registration_ticket,
                   initialise_auth_schema, normalise_email, send_verification_email,
                   password_reset_html, send_password_reset_email,
                   token_hash, totp_matches, utcnow, validate_password, verification_html,
                   verify_email_token, verify_password)

app = FastAPI(title="Kies Drive", version="1.0.0")
KIES_BASE_URL = os.getenv("KIES_BASE_URL", "https://100.72.226.91:8000").rstrip("/")


@app.middleware("http")
async def security_headers(request: Request, call_next):
    """Keep account responses private and browser-based auth tightly scoped."""
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
    if request.url.path.startswith(("/auth/", "/oauth/")):
        response.headers["Cache-Control"] = "no-store"
        response.headers["Pragma"] = "no-cache"
    return response


def db() -> sqlite3.Connection:
    db_path = Path(os.getenv("KIES_DRIVE_DB", "/data/kies-drive.db"))
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
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


class TollSearchRequest(BaseModel):
    origin: str
    destination: str
    via: Optional[list[str]] = None
    avoid_tolls: bool = False


class PasswordResetRequest(BaseModel):
    email: str


class PasswordResetConfirm(BaseModel):
    token: str
    new_password: str


class RegistrationCompletionRequest(BaseModel):
    ticket: str


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


@app.get("/readyz")
def readyz(response: Response):
    """Report production onboarding readiness without exposing any secret."""
    public_url = os.getenv("KIES_DRIVE_PUBLIC_URL", "").strip()
    checks = {
        "public_https": public_url.startswith("https://"),
        "email_delivery": bool(
            os.getenv("SMTP_HOST", "").strip()
            and os.getenv("SMTP_FROM", "").strip()
        ),
    }
    ready = all(checks.values())
    if not ready:
        response.status_code = 503
    return {"ok": ready, "service": "kies-drive", "checks": checks}


def public_url(request: Request) -> str:
    configured = os.getenv("KIES_DRIVE_PUBLIC_URL", "").strip().rstrip("/")
    return configured or str(request.base_url).rstrip("/")


def valid_oauth_redirect(value: str) -> bool:
    try:
        parsed = urlparse(value)
    except ValueError:
        return False
    if parsed.fragment or parsed.username or parsed.password:
        return False
    return bool(parsed.scheme == "https" and parsed.netloc) or (
        parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost"}
    )


@app.get("/.well-known/oauth-authorization-server")
def oauth_metadata(request: Request):
    base = public_url(request)
    return {
        "issuer": base,
        "authorization_endpoint": f"{base}/oauth/authorize",
        "token_endpoint": f"{base}/oauth/token",
        "registration_endpoint": f"{base}/oauth/register",
        "response_types_supported": ["code"],
        "grant_types_supported": ["authorization_code"],
        "scopes_supported": ["mcp"],
        "code_challenge_methods_supported": ["S256"],
        "token_endpoint_auth_methods_supported": ["none"],
    }


@app.get("/.well-known/oauth-protected-resource")
@app.get("/.well-known/oauth-protected-resource/mcp")
def oauth_resource_metadata(request: Request):
    base = public_url(request)
    return {"resource": f"{base}/mcp", "authorization_servers": [base],
            "bearer_methods_supported": ["header"]}


@app.post("/oauth/register", status_code=201)
async def oauth_register(request: Request):
    rate_limit(f"oauth-register:{request.client.host if request.client else 'unknown'}",
               maximum=20, window=3600)
    payload = await request.json()
    redirect_uris = payload.get("redirect_uris") if isinstance(payload, dict) else None
    if not isinstance(redirect_uris, list) or not redirect_uris or len(redirect_uris) > 8 or not all(
        isinstance(uri, str) and valid_oauth_redirect(uri) for uri in redirect_uris
    ):
        raise HTTPException(400, "Ungültige OAuth-Weiterleitungsadresse.")
    client_id = secrets.token_urlsafe(24)
    client_name = str(payload.get("client_name") or "ChatGPT MCP")[:100]
    with db() as conn:
        conn.execute("INSERT INTO oauth_clients(client_id,client_name,redirect_uris,created_at) VALUES(?,?,?,?)",
                     (client_id, client_name, json.dumps(redirect_uris), utcnow().isoformat()))
    return {"client_id": client_id, "client_name": client_name, "redirect_uris": redirect_uris,
            "token_endpoint_auth_method": "none"}


def oauth_client_redirect(client_id: str, redirect_uri: str) -> sqlite3.Row | None:
    with db() as conn:
        client = conn.execute("SELECT * FROM oauth_clients WHERE client_id=?", (client_id,)).fetchone()
    if not client or redirect_uri not in json.loads(client["redirect_uris"]):
        return None
    return client


@app.get("/oauth/authorize", response_class=HTMLResponse)
def oauth_authorize(request: Request, response_type: str, client_id: str, redirect_uri: str,
                    code_challenge: str, code_challenge_method: str, state: str | None = None):
    client = oauth_client_redirect(client_id, redirect_uri)
    if response_type != "code" or code_challenge_method != "S256" or not re.fullmatch(r"[A-Za-z0-9_-]{43,128}", code_challenge):
        raise HTTPException(400, "Diese OAuth-Anfrage wird nicht unterstützt.")
    if not client:
        raise HTTPException(400, "OAuth-Client oder Weiterleitungsadresse ist ungültig.")
    nonce = secrets.token_urlsafe(32)
    with db() as conn:
        conn.execute("DELETE FROM oauth_login_requests WHERE expires_at<?", (utcnow().isoformat(),))
        conn.execute("INSERT INTO oauth_login_requests VALUES(?,?,?,?,?,?)", (
            token_hash(nonce), client_id, redirect_uri, state, code_challenge,
            datetime.fromtimestamp(utcnow().timestamp() + 600, timezone.utc).isoformat(),
        ))
    return HTMLResponse(f"""<!doctype html><html lang=\"de\"><meta name=\"viewport\" content=\"width=device-width\"><title>Kies Drive verbinden</title>
    <body style=\"margin:0;background:#103d32;color:#103d32;font:17px -apple-system;padding:28px\"><main style=\"max-width:480px;margin:8vh auto;background:#f7f0df;padding:28px;border-radius:28px\">
    <h1>Kies Drive verbinden</h1><p><b>{escape(client['client_name'])}</b> darf nach deiner Bestätigung Fahrdaten lesen und freigegebene Routenaktionen senden.</p>
    <form method=\"post\"><input type=\"hidden\" name=\"nonce\" value=\"{escape(nonce, quote=True)}\">
    <input name=\"email\" type=\"email\" required autocomplete=\"email\" placeholder=\"E-Mail-Adresse\" style=\"box-sizing:border-box;width:100%;font:inherit;padding:14px;margin:6px 0;border-radius:12px;border:1px solid #bbb\">
    <input name=\"password\" type=\"password\" required autocomplete=\"current-password\" placeholder=\"Passwort\" style=\"box-sizing:border-box;width:100%;font:inherit;padding:14px;margin:6px 0;border-radius:12px;border:1px solid #bbb\">
    <input name=\"totp_code\" autocomplete=\"one-time-code\" placeholder=\"2FA- oder Wiederherstellungscode (falls aktiv)\" style=\"box-sizing:border-box;width:100%;font:inherit;padding:14px;margin:6px 0;border-radius:12px;border:1px solid #bbb\">
    <button style=\"width:100%;font:600 17px -apple-system;padding:14px;margin-top:12px;border:0;border-radius:14px;background:#103d32;color:white\">Verbinden</button></form></main></body></html>""")


@app.post("/oauth/authorize")
async def oauth_authorize_submit(request: Request):
    fields = {key: values[0] for key, values in parse_qs((await request.body()).decode("utf-8")).items()}
    nonce = fields.get("nonce", "")
    with db() as conn:
        login = conn.execute("SELECT * FROM oauth_login_requests WHERE nonce_hash=? AND expires_at>?",
                             (token_hash(nonce), utcnow().isoformat())).fetchone()
        if not login:
            raise HTTPException(400, "Die Anmeldeanfrage ist abgelaufen.")
        email = normalise_email(fields.get("email", ""))
        rate_limit(f"oauth-login:{request.client.host if request.client else 'unknown'}:{email}")
        user = conn.execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()
        if not user or not user["email_verified_at"] or not verify_password(
            user["password_hash"], fields.get("password", "")
        ):
            raise HTTPException(401, "Anmeldedaten oder Bestätigungscode sind ungültig.")
        supplied = fields.get("totp_code", "")
        if user["totp_secret"] and not (
            totp_matches(user["totp_secret"], supplied)
            or consume_recovery_code(conn, user["id"], supplied)
        ):
            raise HTTPException(401, "Anmeldedaten oder Bestätigungscode sind ungültig.")
        raw_code = secrets.token_urlsafe(32)
        conn.execute("INSERT INTO oauth_authorization_codes VALUES(?,?,?,?,?,?,NULL)", (
            token_hash(raw_code), user["id"], login["client_id"], login["redirect_uri"],
            login["code_challenge"], datetime.fromtimestamp(utcnow().timestamp() + 300, timezone.utc).isoformat(),
        ))
        conn.execute("DELETE FROM oauth_login_requests WHERE nonce_hash=?", (token_hash(nonce),))
    query = {"code": raw_code}
    if login["state"] is not None:
        query["state"] = login["state"]
    separator = "&" if "?" in login["redirect_uri"] else "?"
    return RedirectResponse(f"{login['redirect_uri']}{separator}{urlencode(query)}", status_code=303)


@app.post("/oauth/token")
async def oauth_token(request: Request, response: Response):
    fields = {key: values[0] for key, values in parse_qs((await request.body()).decode("utf-8")).items()}
    if fields.get("grant_type") != "authorization_code":
        raise HTTPException(400, "Nicht unterstützter OAuth-Grant.")
    code, verifier = fields.get("code", ""), fields.get("code_verifier", "")
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    with db() as conn:
        row = conn.execute("SELECT * FROM oauth_authorization_codes WHERE code_hash=? AND used_at IS NULL AND expires_at>?",
                           (token_hash(code), utcnow().isoformat())).fetchone()
        if not row or row["client_id"] != fields.get("client_id") or row["redirect_uri"] != fields.get("redirect_uri") or not secrets.compare_digest(row["code_challenge"], challenge):
            raise HTTPException(400, "OAuth-Code oder PKCE-Prüfung ist ungültig.")
        conn.execute("UPDATE oauth_authorization_codes SET used_at=? WHERE code_hash=?",
                     (utcnow().isoformat(), token_hash(code)))
        access_token, expires_at = create_session(conn, row["user_id"])
    expires_in = max(0, int((datetime.fromisoformat(expires_at) - utcnow()).total_seconds()))
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
    return {"access_token": access_token, "token_type": "Bearer", "expires_in": expires_in,
            "scope": "mcp"}


@app.post("/auth/register", status_code=202)
def register(payload: RegisterRequest, request: Request):
    email = normalise_email(payload.email)
    validate_password(payload.password)
    rate_limit(f"register:{request.client.host if request.client else 'unknown'}", maximum=5, window=3600)
    with db() as conn:
        existing = conn.execute("SELECT id,email_verified_at FROM users WHERE email=?", (email,)).fetchone()
        if existing and existing["email_verified_at"]:
            return {"ok": True, "message": "Falls möglich, wurde eine E-Mail versendet.",
                    "verification_ticket": None}
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
        ticket = create_registration_ticket(conn, user_id)
    try:
        send_verification_email(email, raw)
    except RuntimeError as exc:
        raise HTTPException(503, str(exc)) from exc
    return {"ok": True, "message": "Bitte bestätige deine E-Mail-Adresse.",
            "verification_ticket": ticket}


@app.get("/auth/verify-email", response_class=HTMLResponse)
def verify_email(token: str):
    with db() as conn:
        ok = verify_email_token(conn, token)
    return HTMLResponse(verification_html(ok), status_code=200 if ok else 400)


@app.post("/auth/verification/resend", status_code=202)
def resend_verification(payload: PasswordResetRequest, request: Request):
    email = normalise_email(payload.email)
    rate_limit(f"verification-resend:{request.client.host if request.client else 'unknown'}",
               maximum=4, window=3600)
    delivery = None
    with db() as conn:
        user = conn.execute("SELECT id,email_verified_at FROM users WHERE email=?", (email,)).fetchone()
        if user and not user["email_verified_at"]:
            delivery = create_verification(conn, user["id"])
    if delivery:
        try:
            send_verification_email(email, delivery)
        except RuntimeError as exc:
            raise HTTPException(503, str(exc)) from exc
    # Do not disclose whether the address has an account or is already verified.
    return {"ok": True, "message": "Falls nötig, wurde eine E-Mail versendet."}


@app.post("/auth/verification/complete")
def finish_registration(payload: RegistrationCompletionRequest, response: Response, request: Request):
    rate_limit(f"registration-complete:{request.client.host if request.client else 'unknown'}",
               maximum=20, window=3600)
    with db() as conn:
        result = complete_registration(conn, payload.ticket)
    if not result:
        raise HTTPException(409, "Die E-Mail-Adresse ist noch nicht bestätigt oder die Registrierung ist abgelaufen.")
    session, expires_at, email = result
    response.headers["Cache-Control"] = "no-store"
    return {"session": session, "expires_at": expires_at, "email": email,
            "two_factor_enabled": False}


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
        if user["totp_secret"]:
            supplied = payload.totp_code or ""
            if not supplied:
                raise HTTPException(428, "Zwei-Faktor-Code erforderlich.")
            if not totp_matches(user["totp_secret"], supplied) and not consume_recovery_code(conn, user["id"], supplied):
                raise HTTPException(401, "Der Authenticator- oder Wiederherstellungscode fehlt oder ist ungültig.")
        raw, expires_at = create_session(conn, user["id"])
    AUTH_ATTEMPTS.pop(key, None)
    return {"session": raw, "expires_at": expires_at, "email": email,
            "two_factor_enabled": bool(user["totp_secret"])}


@app.post("/auth/password/request", status_code=202)
def request_password_reset(payload: PasswordResetRequest, request: Request):
    email = normalise_email(payload.email)
    rate_limit(f"password-reset:{request.client.host if request.client else 'unknown'}", maximum=5, window=3600)
    delivery = None
    with db() as conn:
        user = conn.execute("SELECT id,email_verified_at FROM users WHERE email=?", (email,)).fetchone()
        if user and user["email_verified_at"]:
            delivery = create_password_reset(conn, user["id"])
    if delivery:
        try:
            send_password_reset_email(email, delivery)
        except RuntimeError as exc:
            raise HTTPException(503, str(exc)) from exc
    return {"ok": True, "message": "Falls ein Konto existiert, wurde eine E-Mail versendet."}


@app.get("/auth/password/reset", response_class=HTMLResponse)
def password_reset_page(token: str):
    return HTMLResponse(password_reset_html(token))


@app.post("/auth/password/reset")
def reset_password(payload: PasswordResetConfirm, request: Request):
    rate_limit(f"password-reset-confirm:{request.client.host if request.client else 'unknown'}")
    with db() as conn:
        ok = consume_password_reset(conn, payload.token, payload.new_password)
    if not ok:
        raise HTTPException(400, "Der Link ist ungültig oder abgelaufen.")
    return {"ok": True}


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


@app.delete("/auth/account")
def delete_account(authorization: str | None = Header(None)):
    with db() as conn:
        user = authenticated_user(conn, authorization)
        user_id = user["id"]
        conn.execute("DELETE FROM user_commands WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM user_state WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM email_verifications WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM registration_completions WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM password_resets WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM two_factor_recovery_codes WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM sessions WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM users WHERE id=?", (user_id,))
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
        recovery_codes = create_recovery_codes(conn, user["id"])
        # Enabling a second factor is a security boundary. Keep the device
        # performing the setup signed in, but revoke every older session so a
        # previously copied session cannot bypass the newly enabled factor.
        conn.execute(
            "UPDATE sessions SET revoked_at=? WHERE user_id=? AND id<>? AND revoked_at IS NULL",
            (utcnow().isoformat(), user["id"], user["session_id"]),
        )
    return {"ok": True, "recovery_codes": recovery_codes}


def explicit_toll_amount(text: str) -> float | None:
    """Accept only an amount explicitly labelled as the total toll price."""
    patterns = (
        r"(?:gesamtmaut|mautkosten|toll costs?)\s*(?:von|:|-)?\s*(\d{1,4}(?:[.,]\d{1,2})?)\s*(?:€|eur)",
        r"(\d{1,4}(?:[.,]\d{1,2})?)\s*(?:€|eur)\s*(?:gesamtmaut|mautkosten|toll costs?)",
    )
    lowered = text.lower()
    for pattern in patterns:
        if match := re.search(pattern, lowered):
            amount = float(match.group(1).replace(",", "."))
            return amount if 0 <= amount <= 5_000 else None
    return None


def explicit_no_toll(text: str) -> bool:
    """Accept only an explicit statement that the complete route is toll-free."""
    lowered = text.lower()
    patterns = (
        r"(?:gesamte route|strecke|route).{0,40}(?:mautfrei|ohne maut|keine maut)",
        r"(?:mautfrei|ohne maut|keine maut).{0,40}(?:gesamte route|strecke|route)",
        r"(?:gesamtmaut|mautkosten)\s*(?::|-)?\s*0(?:[.,]00)?\s*(?:€|eur)",
    )
    return any(re.search(pattern, lowered) for pattern in patterns)


def toll_source_matches_route(text: str, origin: str, destination: str,
                              via: list[str]) -> bool:
    """Require both route endpoints and every mandatory via point in evidence."""
    haystack = text.casefold()
    stop_words = {
        "der", "die", "das", "den", "dem", "von", "nach", "via", "und", "the",
        "am", "an", "auf", "bei", "route", "strecke", "straße", "strasse",
        "autobahn", "auffahrt",
    }
    # Labels are formed as "place, region, country" or as a named mandatory
    # point. The first meaningful token is therefore the route identity; a
    # generic secondary token such as "Main", "Steiermark" or "Kroatien"
    # must not make an unrelated route look corroborated.
    identities: list[str | None] = []
    for label in [origin, destination, *via]:
        tokens = [
            token.casefold()
            for token in re.findall(r"[\wÀ-ÿ-]{3,}", label)
            if not token.isdigit() and token.casefold() not in stop_words
        ]
        identities.append(tokens[0] if tokens else None)
    return bool(identities) and all(identity and identity in haystack
                                    for identity in identities)


OFFICIAL_TOLL_HOSTS = ("asfinag.at", "dars.si", "hac.hr", "autostrade.it",
                       "vinci-autoroutes.com")


def independent_source_domain(host: str) -> str:
    """Collapse subdomains so one publisher cannot corroborate itself."""
    labels = host.lower().strip(".").split(".")
    if len(labels) <= 2:
        return ".".join(labels)
    common_second_level_suffixes = {
        "co.uk", "org.uk", "com.au", "com.br", "co.jp", "co.nz", "co.za",
    }
    suffix = ".".join(labels[-2:])
    return ".".join(labels[-3:]) if suffix in common_second_level_suffixes else suffix


def verified_toll_evidence(sources: list[dict[str, str]], origin: str,
                           destination: str, via: list[str]) -> tuple[float, str, str] | None:
    """Accept one official source or two independent corroborating domains."""
    evidence: list[tuple[float, str, str, str, bool]] = []
    for source in sources:
        source_text = f"{source['title']} {source['snippet']}"
        amount = explicit_toll_amount(source_text)
        parsed = urlparse(source["url"])
        host = (parsed.hostname or "").lower()
        if (amount is None or parsed.scheme != "https" or not host
                or not toll_source_matches_route(source_text, origin, destination, via)):
            continue
        official = any(host == domain or host.endswith(f".{domain}")
                       for domain in OFFICIAL_TOLL_HOSTS)
        evidence.append((amount, independent_source_domain(host), source["title"], source["url"], official))
    if official := next((item for item in evidence if item[4]), None):
        return official[0], official[2], official[3]
    for amount, _, _, _, _ in evidence:
        corroborating = [item for item in evidence if abs(item[0] - amount) <= 0.01]
        if len({item[1] for item in corroborating}) >= 2:
            titles = " + ".join(dict.fromkeys(item[2] for item in corroborating))[:300]
            return amount, titles, corroborating[0][3]
    return None


def verified_no_toll_evidence(sources: list[dict[str, str]], origin: str,
                              destination: str, via: list[str]) -> tuple[str, str] | None:
    """Require official evidence or two domains before claiming zero toll."""
    evidence: list[tuple[str, str, str, bool]] = []
    for source in sources:
        source_text = f"{source['title']} {source['snippet']}"
        parsed = urlparse(source["url"])
        host = (parsed.hostname or "").lower()
        if (parsed.scheme != "https" or not host or not explicit_no_toll(source_text)
                or not toll_source_matches_route(source_text, origin, destination, via)):
            continue
        official = any(host == domain or host.endswith(f".{domain}")
                       for domain in OFFICIAL_TOLL_HOSTS)
        evidence.append((independent_source_domain(host), source["title"], source["url"], official))
    if official := next((item for item in evidence if item[3]), None):
        return official[1], official[2]
    if len({item[0] for item in evidence}) >= 2:
        titles = " + ".join(dict.fromkeys(item[1] for item in evidence))[:300]
        return titles, evidence[0][2]
    return None


@app.post("/api/navigation/toll-search")
async def toll_search(payload: TollSearchRequest, authorization: str | None = Header(None)):
    current_user(authorization)
    searxng_url = os.getenv("SEARXNG_URL", "").strip().rstrip("/")
    if not searxng_url.startswith(("http://", "https://")):
        raise HTTPException(503, "SearXNG ist im Kies-Drive-Container noch nicht eingerichtet.")
    origin = payload.origin.strip()[:180]
    destination = payload.destination.strip()[:180]
    via = [name.strip()[:120] for name in (payload.via or [])[:8] if name.strip()]
    if len(origin) < 2 or len(destination) < 2:
        raise HTTPException(422, "Start und Ziel fehlen.")
    via_query = f" über {' '.join(via)}" if via else ""
    if payload.avoid_tolls:
        query = f"PKW mautfreie Route keine Maut {origin} nach {destination}{via_query} {date.today().year}"
    else:
        query = f"PKW Mautkosten Gesamtmaut {origin} nach {destination}{via_query} {date.today().year}"
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.get(f"{searxng_url}/search", params={
                "q": query, "format": "json", "language": "de-DE", "safesearch": 1,
            })
            response.raise_for_status()
            results = response.json().get("results", [])
    except (httpx.HTTPError, ValueError, TypeError) as exc:
        raise HTTPException(502, "SearXNG ist gerade nicht erreichbar.") from exc
    sources = [{
        "title": str(item.get("title") or "Suchtreffer")[:300],
        "url": str(item.get("url") or "")[:2_000],
        "snippet": str(item.get("content") or item.get("snippet") or "")[:1_000],
    } for item in results[:5] if isinstance(item, dict)]
    if payload.avoid_tolls and (evidence := verified_no_toll_evidence(
            sources, origin, destination, via)):
        source_name, source_url = evidence
        return {"status": "no_toll", "amount": 0, "currency": "EUR",
                "source": source_name, "source_url": source_url, "sources": sources}
    if evidence := verified_toll_evidence(sources, origin, destination, via):
        amount, source_name, source_url = evidence
        return {"status": "known", "amount": amount, "currency": "EUR",
                "source": source_name, "source_url": source_url, "sources": sources}
    return {"status": "unknown", "amount": None, "currency": "EUR",
            "source": "SearXNG", "source_url": None, "sources": sources}


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
    {"name": "get_command_status", "description": "Ausführung einer Remote-Aktion prüfen", "inputSchema": {
        "type": "object", "properties": {"command_id": {"type": "integer", "minimum": 1}},
        "required": ["command_id"], "additionalProperties": False}},
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
    try:
        user = current_user(authorization)
    except HTTPException as exc:
        metadata = f"{public_url(request)}/.well-known/oauth-protected-resource"
        raise HTTPException(exc.status_code, exc.detail, headers={
            "WWW-Authenticate": f'Bearer resource_metadata="{metadata}"'
        }) from exc
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
            if name == "get_command_status":
                command_id = args.get("command_id")
                row = conn.execute(
                    "SELECT status,result FROM user_commands WHERE id=? AND user_id=?",
                    (command_id, user["id"]),
                ).fetchone() if isinstance(command_id, int) and command_id > 0 else None
                parsed_result = None
                if row and row["result"]:
                    try:
                        parsed_result = json.loads(row["result"])
                    except (TypeError, json.JSONDecodeError):
                        parsed_result = {"message": "Ungültige Ergebnisdaten"}
                data = {
                    "found": row is not None,
                    "command_id": command_id,
                    "status": row["status"] if row else "unknown",
                    "result": parsed_result,
                }
            elif isinstance(name, str) and name.startswith("get_"):
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
                data = {"accepted": True, "command_id": cur.lastrowid, "status": "pending"}
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
    legacy_token = os.getenv("KIES_DEVICE_TOKEN", "").strip()
    if not legacy_token:
        raise HTTPException(503, "Der optionale Kies-Zusatzdienst ist nicht eingerichtet.")
    headers = {"X-Kies-Device-Token": legacy_token}
    verify_tls = os.getenv("KIES_VERIFY_TLS", "true").lower() != "false"
    async with httpx.AsyncClient(verify=verify_tls, timeout=30) as client:
        upstream = await client.request(request.method, f"{KIES_BASE_URL}/api/navigation/{path}", params=request.query_params,
                                        content=await request.body(), headers=headers)
    return Response(upstream.content, status_code=upstream.status_code, media_type=upstream.headers.get("content-type"))


@app.post("/api/jarvis/chat")
async def jarvis_proxy(request: Request, authorization: str | None = Header(None)):
    """Keep the existing assistant integration while Kies Drive is deployed separately."""
    current_user(authorization)
    legacy_token = os.getenv("KIES_DEVICE_TOKEN", "").strip()
    if not legacy_token:
        raise HTTPException(503, "Der optionale Kies-Assistent ist nicht eingerichtet.")
    headers = {"X-Kies-Device-Token": legacy_token}
    verify_tls = os.getenv("KIES_VERIFY_TLS", "true").lower() != "false"
    async with httpx.AsyncClient(verify=verify_tls, timeout=30) as client:
        upstream = await client.post(
            f"{KIES_BASE_URL}/api/jarvis/chat",
            content=await request.body(),
            headers=headers,
        )
    return Response(upstream.content, status_code=upstream.status_code, media_type=upstream.headers.get("content-type"))
