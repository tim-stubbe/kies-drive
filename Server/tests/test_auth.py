import pyotp
from fastapi.testclient import TestClient

import app.main as main


def test_toll_amount_parser_accepts_only_explicit_total():
    assert main.explicit_toll_amount("Mautkosten: 27,40 EUR") == 27.4
    assert main.explicit_toll_amount("27.40 € Gesamtmaut") == 27.4
    assert main.explicit_toll_amount("Vignette 11,50 € und Tunnel 14 €") is None
    assert main.explicit_toll_amount("Mautkosten: 99999 EUR") is None


def test_verification_email_can_be_resent_without_account_disclosure(tmp_path, monkeypatch):
    monkeypatch.setenv("KIES_DRIVE_DB", str(tmp_path / "auth.db"))
    sent = []
    monkeypatch.setattr(main, "send_verification_email", lambda email, token: sent.append((email, token)))
    main.AUTH_ATTEMPTS.clear()
    client = TestClient(main.app)

    assert client.post("/auth/register", json={"email": "new@example.com", "password": "a-secure-password"}).status_code == 202
    first_token = sent[-1][1]
    response = client.post("/auth/verification/resend", json={"email": "new@example.com"})
    assert response.status_code == 202
    assert sent[-1][1] != first_token

    count = len(sent)
    assert client.post("/auth/verification/resend", json={"email": "missing@example.com"}).status_code == 202
    assert len(sent) == count


def test_registration_verification_login_and_totp(tmp_path, monkeypatch):
    monkeypatch.setenv("KIES_DRIVE_DB", str(tmp_path / "auth.db"))
    sent = {}
    monkeypatch.setattr(main, "send_verification_email",
                        lambda email, token: sent.update(email=email, token=token))
    main.AUTH_ATTEMPTS.clear()
    client = TestClient(main.app)
    email = "driver@example.com"
    password = "a-really-secure-password"

    response = client.post("/auth/register", json={"email": email, "password": password})
    assert response.status_code == 202
    assert sent["email"] == email

    response = client.get("/auth/verify-email", params={"token": sent["token"]})
    assert response.status_code == 200
    response = client.get("/auth/verify-email", params={"token": sent["token"]})
    assert response.status_code == 400

    response = client.post("/auth/login", json={"email": email, "password": password})
    assert response.status_code == 200
    session = response.json()["session"]
    headers = {"Authorization": f"Bearer {session}"}
    profile = client.get("/auth/me", headers=headers)
    assert profile.status_code == 200
    assert profile.json()["email_verified"] is True

    setup = client.post("/auth/2fa/setup", headers=headers)
    assert setup.status_code == 200
    secret = setup.json()["secret"]
    enabled = client.post("/auth/2fa/enable", headers=headers,
                          json={"code": pyotp.TOTP(secret).now()})
    assert enabled.status_code == 200

    assert client.post("/auth/login", json={"email": email, "password": password}).status_code == 401
    signed_in = client.post("/auth/login", json={
        "email": email, "password": password, "totp_code": pyotp.TOTP(secret).now()
    })
    assert signed_in.status_code == 200
    final_headers = {"Authorization": f"Bearer {signed_in.json()['session']}"}
    assert client.delete("/auth/account", headers=final_headers).status_code == 200
    assert client.get("/auth/me", headers=final_headers).status_code == 401


def test_password_and_authentication_guards(tmp_path, monkeypatch):
    monkeypatch.setenv("KIES_DRIVE_DB", str(tmp_path / "guards.db"))
    monkeypatch.setattr(main, "send_verification_email", lambda email, token: None)
    main.AUTH_ATTEMPTS.clear()
    client = TestClient(main.app)

    assert client.post("/auth/register", json={"email": "bad", "password": "long-enough-password"}).status_code == 422
    assert client.post("/auth/register", json={"email": "ok@example.com", "password": "short"}).status_code == 422
    assert client.get("/auth/me").status_code == 401
    assert client.put("/api/navigation/remote/state", json={}).status_code == 401


def test_password_reset_is_private_single_use_and_revokes_sessions(tmp_path, monkeypatch):
    monkeypatch.setenv("KIES_DRIVE_DB", str(tmp_path / "reset.db"))
    verification = {}
    reset = {}
    monkeypatch.setattr(main, "send_verification_email",
                        lambda email, token: verification.update(email=email, token=token))
    monkeypatch.setattr(main, "send_password_reset_email",
                        lambda email, token: reset.update(email=email, token=token))
    main.AUTH_ATTEMPTS.clear()
    client = TestClient(main.app)
    email = "reset@example.com"
    old_password = "the-old-secure-password"
    new_password = "the-new-secure-password"
    client.post("/auth/register", json={"email": email, "password": old_password})
    client.get("/auth/verify-email", params={"token": verification["token"]})
    signed_in = client.post("/auth/login", json={"email": email, "password": old_password})
    old_headers = {"Authorization": f"Bearer {signed_in.json()['session']}"}

    unknown = client.post("/auth/password/request", json={"email": "missing@example.com"})
    requested = client.post("/auth/password/request", json={"email": email})
    assert unknown.status_code == requested.status_code == 202
    assert unknown.json()["message"] == requested.json()["message"]
    assert reset["email"] == email
    assert client.get("/auth/password/reset", params={"token": reset["token"]}).status_code == 200

    changed = client.post("/auth/password/reset", json={"token": reset["token"], "new_password": new_password})
    assert changed.status_code == 200
    assert client.post("/auth/password/reset", json={"token": reset["token"], "new_password": new_password}).status_code == 400
    assert client.get("/auth/me", headers=old_headers).status_code == 401
    assert client.post("/auth/login", json={"email": email, "password": old_password}).status_code == 401
    assert client.post("/auth/login", json={"email": email, "password": new_password}).status_code == 200
