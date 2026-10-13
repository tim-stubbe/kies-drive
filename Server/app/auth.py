from __future__ import annotations

import hashlib
import os
import re
import secrets
import smtplib
import sqlite3
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from html import escape

import pyotp
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from fastapi import Header, HTTPException


PASSWORD_HASHER = PasswordHasher(memory_cost=19456, time_cost=2, parallelism=1)
EMAIL_PATTERN = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
SESSION_DAYS = 30
VERIFY_HOURS = 24
RESET_MINUTES = 30


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def token_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def normalise_email(value: str) -> str:
    email = value.strip().lower()
    if len(email) > 254 or not EMAIL_PATTERN.fullmatch(email):
        raise HTTPException(422, "Bitte gib eine gültige E-Mail-Adresse ein.")
    return email


def validate_password(value: str) -> None:
    if len(value) < 12 or len(value) > 256:
        raise HTTPException(422, "Das Passwort muss mindestens 12 Zeichen lang sein.")


def initialise_auth_schema(conn: sqlite3.Connection) -> None:
    conn.executescript("""
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        email TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        email_verified_at TEXT,
        totp_secret TEXT,
        totp_pending_secret TEXT,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS email_verifications (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        token_hash TEXT NOT NULL UNIQUE,
        expires_at TEXT NOT NULL,
        used_at TEXT,
        FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
      );
      CREATE TABLE IF NOT EXISTS sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        token_hash TEXT NOT NULL UNIQUE,
        expires_at TEXT NOT NULL,
        revoked_at TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS sessions_token_idx ON sessions(token_hash);
      CREATE TABLE IF NOT EXISTS password_resets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        token_hash TEXT NOT NULL UNIQUE,
        expires_at TEXT NOT NULL,
        used_at TEXT,
        FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    """)
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(users)").fetchall()}
    if "totp_pending_secret" not in columns:
        conn.execute("ALTER TABLE users ADD COLUMN totp_pending_secret TEXT")


def create_verification(conn: sqlite3.Connection, user_id: int) -> str:
    raw = secrets.token_urlsafe(32)
    now = utcnow()
    conn.execute("DELETE FROM email_verifications WHERE user_id=? AND used_at IS NULL", (user_id,))
    conn.execute(
        "INSERT INTO email_verifications(user_id,token_hash,expires_at) VALUES(?,?,?)",
        (user_id, token_hash(raw), (now + timedelta(hours=VERIFY_HOURS)).isoformat()),
    )
    return raw


def send_verification_email(email: str, raw_token: str) -> None:
    public_url = os.getenv("KIES_DRIVE_PUBLIC_URL", "").rstrip("/")
    host = os.getenv("SMTP_HOST", "").strip()
    sender = os.getenv("SMTP_FROM", "").strip()
    if not public_url or not host or not sender:
        raise RuntimeError("E-Mail-Versand ist noch nicht konfiguriert.")
    link = f"{public_url}/auth/verify-email?token={raw_token}"
    message = EmailMessage()
    message["Subject"] = "E-Mail-Adresse für Kies Drive bestätigen"
    message["From"] = sender
    message["To"] = email
    message.set_content(
        "Willkommen bei Kies Drive.\n\n"
        f"Bestätige deine E-Mail-Adresse innerhalb von {VERIFY_HOURS} Stunden:\n{link}\n\n"
        "Falls du dich nicht registriert hast, kannst du diese Nachricht ignorieren."
    )
    port = int(os.getenv("SMTP_PORT", "587"))
    username = os.getenv("SMTP_USERNAME", "")
    password = os.getenv("SMTP_PASSWORD", "")
    with smtplib.SMTP(host, port, timeout=15) as smtp:
        if os.getenv("SMTP_STARTTLS", "true").lower() == "true":
            smtp.starttls()
        if username:
            smtp.login(username, password)
        smtp.send_message(message)


def verify_email_token(conn: sqlite3.Connection, raw_token: str) -> bool:
    row = conn.execute(
        "SELECT id,user_id,expires_at,used_at FROM email_verifications WHERE token_hash=?",
        (token_hash(raw_token),),
    ).fetchone()
    if not row or row["used_at"] or datetime.fromisoformat(row["expires_at"]) < utcnow():
        return False
    now = utcnow().isoformat()
    conn.execute("UPDATE email_verifications SET used_at=? WHERE id=?", (now, row["id"]))
    conn.execute("UPDATE users SET email_verified_at=? WHERE id=?", (now, row["user_id"]))
    return True


def create_password_reset(conn: sqlite3.Connection, user_id: int) -> str:
    raw = secrets.token_urlsafe(32)
    now = utcnow()
    conn.execute("DELETE FROM password_resets WHERE user_id=? AND used_at IS NULL", (user_id,))
    conn.execute(
        "INSERT INTO password_resets(user_id,token_hash,expires_at) VALUES(?,?,?)",
        (user_id, token_hash(raw), (now + timedelta(minutes=RESET_MINUTES)).isoformat()),
    )
    return raw


def send_password_reset_email(email: str, raw_token: str) -> None:
    public_url = os.getenv("KIES_DRIVE_PUBLIC_URL", "").rstrip("/")
    host = os.getenv("SMTP_HOST", "").strip()
    sender = os.getenv("SMTP_FROM", "").strip()
    if not public_url or not host or not sender:
        raise RuntimeError("E-Mail-Versand ist noch nicht konfiguriert.")
    link = f"{public_url}/auth/password/reset?token={raw_token}"
    message = EmailMessage()
    message["Subject"] = "Kies-Drive-Passwort zurücksetzen"
    message["From"] = sender
    message["To"] = email
    message.set_content(
        "Für dein Kies-Drive-Konto wurde ein neues Passwort angefordert.\n\n"
        f"Lege innerhalb von {RESET_MINUTES} Minuten ein neues Passwort fest:\n{link}\n\n"
        "Falls du das nicht warst, ignoriere diese Nachricht. Dein Passwort bleibt unverändert."
    )
    port = int(os.getenv("SMTP_PORT", "587"))
    username = os.getenv("SMTP_USERNAME", "")
    password = os.getenv("SMTP_PASSWORD", "")
    with smtplib.SMTP(host, port, timeout=15) as smtp:
        if os.getenv("SMTP_STARTTLS", "true").lower() == "true":
            smtp.starttls()
        if username:
            smtp.login(username, password)
        smtp.send_message(message)


def consume_password_reset(conn: sqlite3.Connection, raw_token: str, new_password: str) -> bool:
    validate_password(new_password)
    row = conn.execute(
        "SELECT id,user_id,expires_at,used_at FROM password_resets WHERE token_hash=?",
        (token_hash(raw_token),),
    ).fetchone()
    if not row or row["used_at"] or datetime.fromisoformat(row["expires_at"]) < utcnow():
        return False
    now = utcnow().isoformat()
    conn.execute("UPDATE password_resets SET used_at=? WHERE id=?", (now, row["id"]))
    conn.execute("UPDATE users SET password_hash=? WHERE id=?", (PASSWORD_HASHER.hash(new_password), row["user_id"]))
    conn.execute("UPDATE sessions SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL", (now, row["user_id"]))
    return True


def verify_password(stored: str, supplied: str) -> bool:
    try:
        return PASSWORD_HASHER.verify(stored, supplied)
    except VerifyMismatchError:
        return False


def create_session(conn: sqlite3.Connection, user_id: int) -> tuple[str, str]:
    raw = secrets.token_urlsafe(48)
    now = utcnow()
    expires = now + timedelta(days=SESSION_DAYS)
    conn.execute(
        "INSERT INTO sessions(user_id,token_hash,expires_at,created_at) VALUES(?,?,?,?)",
        (user_id, token_hash(raw), expires.isoformat(), now.isoformat()),
    )
    return raw, expires.isoformat()


def authenticated_user(conn: sqlite3.Connection, authorization: str | None) -> sqlite3.Row:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Bitte melde dich an.")
    raw = authorization.removeprefix("Bearer ").strip()
    row = conn.execute(
        """SELECT users.*, sessions.id AS session_id
           FROM sessions JOIN users ON users.id=sessions.user_id
           WHERE sessions.token_hash=? AND sessions.revoked_at IS NULL AND sessions.expires_at>?""",
        (token_hash(raw), utcnow().isoformat()),
    ).fetchone()
    if not row:
        raise HTTPException(401, "Deine Sitzung ist abgelaufen. Bitte melde dich erneut an.")
    return row


def user_dependency(conn_factory, authorization: str | None = Header(None)) -> sqlite3.Row:
    with conn_factory() as conn:
        return authenticated_user(conn, authorization)


def totp_matches(secret: str, code: str) -> bool:
    clean = re.sub(r"\s", "", code)
    return bool(re.fullmatch(r"\d{6}", clean)) and pyotp.TOTP(secret).verify(clean, valid_window=1)


def verification_html(ok: bool) -> str:
    title = "E-Mail bestätigt" if ok else "Link ungültig oder abgelaufen"
    detail = "Du kannst jetzt zu Kies Drive zurückkehren und dich anmelden." if ok else "Fordere in Kies Drive eine neue Bestätigungs-E-Mail an."
    return f"""<!doctype html><html lang=\"de\"><meta name=\"viewport\" content=\"width=device-width\"><title>{escape(title)}</title>
    <body style=\"margin:0;background:#f5f0e2;color:#123d32;font:18px -apple-system;padding:48px\"><main style=\"max-width:520px;margin:auto\">
    <h1>{escape(title)}</h1><p>{escape(detail)}</p><a href=\"kiesdrive://auth-complete\">Kies Drive öffnen</a></main></body></html>"""


def password_reset_html(raw_token: str) -> str:
    token = escape(raw_token, quote=True)
    return f"""<!doctype html><html lang=\"de\"><meta name=\"viewport\" content=\"width=device-width\"><title>Passwort zurücksetzen</title>
    <body style=\"margin:0;background:#f5f0e2;color:#123d32;font:18px -apple-system;padding:32px\"><main style=\"max-width:520px;margin:auto\">
    <h1>Neues Passwort</h1><p>Verwende mindestens 12 Zeichen.</p>
    <form id=\"reset\"><input id=\"password\" type=\"password\" minlength=\"12\" required autocomplete=\"new-password\" style=\"box-sizing:border-box;width:100%;font:inherit;padding:14px;border-radius:12px;border:1px solid #aaa\">
    <button style=\"margin-top:16px;width:100%;font:600 18px -apple-system;padding:14px;border:0;border-radius:12px;background:#123d32;color:white\">Passwort speichern</button></form><p id=\"result\"></p>
    <script>document.getElementById('reset').addEventListener('submit',async(e)=>{{e.preventDefault();const r=await fetch('/auth/password/reset',{{method:'POST',headers:{{'content-type':'application/json'}},body:JSON.stringify({{token:'{token}',new_password:document.getElementById('password').value}})}});const j=await r.json();document.getElementById('result').textContent=r.ok?'Passwort geändert. Du kannst dich jetzt in Kies Drive anmelden.':(j.detail||'Der Link ist ungültig oder abgelaufen.');}});</script>
    </main></body></html>"""
