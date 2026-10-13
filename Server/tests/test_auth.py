import pyotp
from fastapi.testclient import TestClient

import app.main as main


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
