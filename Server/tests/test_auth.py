import base64
import hashlib
import json
import re
from urllib.parse import parse_qs, urlparse

import pyotp
from fastapi.testclient import TestClient

import app.main as main


def test_production_readiness_discloses_no_secrets(monkeypatch):
    monkeypatch.delenv("KIES_DRIVE_PUBLIC_URL", raising=False)
    monkeypatch.delenv("SMTP_HOST", raising=False)
    monkeypatch.delenv("SMTP_FROM", raising=False)
    client = TestClient(main.app)

    missing = client.get("/readyz")
    assert missing.status_code == 503
    assert missing.json()["checks"] == {
        "public_https": False,
        "email_delivery": False,
    }

    monkeypatch.setenv("KIES_DRIVE_PUBLIC_URL", "https://drive.example.test")
    monkeypatch.setenv("SMTP_HOST", "smtp.example.test")
    monkeypatch.setenv("SMTP_FROM", "Kies Drive <drive@example.test>")
    monkeypatch.setenv("SMTP_PASSWORD", "must-never-be-returned")
    ready = client.get("/readyz")
    assert ready.status_code == 200
    assert ready.json()["ok"] is True
    assert "must-never-be-returned" not in ready.text


def test_account_responses_are_not_cached_or_embedded(tmp_path, monkeypatch):
    monkeypatch.setenv("KIES_DRIVE_DB", str(tmp_path / "headers.db"))
    monkeypatch.setattr(main, "send_verification_email", lambda email, token: None)
    main.AUTH_ATTEMPTS.clear()
    response = TestClient(main.app).post(
        "/auth/register",
        json={"email": "headers@example.com", "password": "a-secure-password"},
    )

    assert response.status_code == 202
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["x-frame-options"] == "DENY"
    assert response.headers["referrer-policy"] == "no-referrer"


def test_toll_amount_parser_accepts_only_explicit_total():
    assert main.explicit_toll_amount("Mautkosten: 27,40 EUR") == 27.4
    assert main.explicit_toll_amount("27.40 € Gesamtmaut") == 27.4
    assert main.explicit_toll_amount("Vignette 11,50 € und Tunnel 14 €") is None
    assert main.explicit_toll_amount("Mautkosten: 99999 EUR") is None


def test_no_toll_parser_requires_complete_route_statement():
    assert main.explicit_no_toll("Die gesamte Route ist mautfrei")
    assert main.explicit_no_toll("Die Strecke ist vollständig ohne Maut befahrbar")
    assert main.explicit_no_toll("Gesamtmaut: 0,00 EUR")
    assert not main.explicit_no_toll("Dieser kurze Abschnitt ist mautfrei")
    assert not main.explicit_no_toll("Ein Abschnitt der Strecke ist mautfrei")
    assert not main.explicit_no_toll("Auf dieser Route ist ein Teilstück ohne Maut")


def test_toll_source_must_match_destination_or_required_via_point():
    assert main.toll_source_matches_route(
        "Split nach Hochheim Gesamtmaut: 27,40 EUR über den Wurzenpass",
        "Split", "Hochheim am Main", ["Wurzenpass"]
    )
    assert not main.toll_source_matches_route(
        "Wurzenpass Mautkosten: 27,40 EUR", "Split", "Hochheim am Main", ["Wurzenpass"]
    )
    assert not main.toll_source_matches_route(
        "Paris nach Lyon Mautkosten: 27,40 EUR", "Split", "Hochheim am Main", ["Wurzenpass"]
    )
    assert not main.toll_source_matches_route(
        "Graz nach Hochheim Gesamtmaut: 27,40 EUR über den Wurzenpass",
        "Split", "Hochheim am Main", ["Wurzenpass"]
    )
    assert main.toll_source_matches_route(
        "Ulm nach Rom: Gesamtmaut 22 EUR", "Ulm", "Rom", []
    )
    assert not main.toll_source_matches_route(
        "Ulm nach Stromberg: Gesamtmaut 22 EUR", "Ulm", "Rom", []
    )
    assert not main.toll_source_matches_route(
        "Split nach Frankfurt am Main über Wurzenpass Gesamtmaut: 27,40 EUR",
        "Split, Kroatien", "Hochheim am Main", ["Wurzenpass (B109)"]
    )
    assert main.toll_source_matches_route(
        "Split nach Hochheim über Wurzenpass Gesamtmaut: 27,40 EUR",
        "Split, Kroatien", "Hochheim am Main", ["Wurzenpass (B109)"]
    )


def test_toll_evidence_requires_official_or_independent_corroboration():
    route_text = f"Split nach Hochheim über Wurzenpass Gesamtmaut: 27,40 EUR {main.date.today().year}"
    unofficial = {"title": route_text, "snippet": "", "url": "https://blog.example/trip"}
    assert main.verified_toll_evidence(
        [unofficial], "Split", "Hochheim am Main", ["Wurzenpass"]
    ) is None

    second = {"title": f"Mautkosten: 27,40 EUR Split Hochheim via Wurzenpass {main.date.today().year}",
              "snippet": "", "url": "https://calculator.example/route"}
    evidence = main.verified_toll_evidence(
        [unofficial, second], "Split", "Hochheim am Main", ["Wurzenpass"]
    )
    assert evidence is not None
    assert evidence[0] == 27.4

    official = {"title": route_text, "snippet": "", "url": "https://shop.asfinag.at/route"}
    assert main.verified_toll_evidence(
        [official], "Split", "Hochheim am Main", ["Wurzenpass"]
    )[0] == 27.4


def test_toll_evidence_does_not_count_subdomains_as_independent_sources():
    route_text = f"Split nach Hochheim über Wurzenpass Gesamtmaut: 27,40 EUR {main.date.today().year}"
    sources = [
        {"title": route_text, "snippet": "", "url": "https://route.example.com/trip"},
        {"title": route_text, "snippet": "", "url": "https://blog.example.com/trip"},
    ]

    assert main.independent_source_domain("route.example.com") == "example.com"
    assert main.independent_source_domain("prices.example.co.uk") == "example.co.uk"
    assert main.verified_toll_evidence(
        sources, "Split", "Hochheim am Main", ["Wurzenpass"]
    ) is None


def test_no_toll_evidence_requires_official_or_two_independent_sources():
    text = f"Split nach Hochheim über Wurzenpass: gesamte Route mautfrei {main.date.today().year}"
    one = {"title": text, "snippet": "", "url": "https://blog.example/trip"}
    assert main.verified_no_toll_evidence(
        [one], "Split", "Hochheim am Main", ["Wurzenpass"]
    ) is None
    two = {"title": text, "snippet": "", "url": "https://routes.example/trip"}
    assert main.verified_no_toll_evidence(
        [one, two], "Split", "Hochheim am Main", ["Wurzenpass"]
    ) is not None

    same_publisher = {"title": text, "snippet": "", "url": "https://news.blog.example/trip"}
    assert main.verified_no_toll_evidence(
        [one, same_publisher], "Split", "Hochheim am Main", ["Wurzenpass"]
    ) is None


def test_unofficial_toll_evidence_must_be_current():
    old = "Split nach Hochheim über Wurzenpass Gesamtmaut: 27,40 EUR 2024"
    sources = [
        {"title": old, "snippet": "", "url": "https://old.example/trip"},
        {"title": old, "snippet": "", "url": "https://archive.example.net/trip"},
    ]
    assert not main.toll_source_is_current(old, official=False, current_year=2026)
    assert main.toll_source_is_current(old, official=True, current_year=2026)
    assert main.verified_toll_evidence(
        sources, "Split", "Hochheim am Main", ["Wurzenpass"]
    ) is None


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
    ticket = response.json()["verification_ticket"]
    assert ticket
    assert client.post("/auth/verification/complete", json={"ticket": ticket}).status_code == 409

    response = client.get("/auth/verify-email", params={"token": sent["token"]})
    assert response.status_code == 200
    assert "meldet dich automatisch an" in response.text
    assert 'href="kiesdrive://auth-complete"' in response.text
    response = client.get("/auth/verify-email", params={"token": sent["token"]})
    assert response.status_code == 400

    completed = client.post("/auth/verification/complete", json={"ticket": ticket})
    assert completed.status_code == 200
    assert completed.headers["cache-control"] == "no-store"
    assert completed.json()["email"] == email
    assert client.get("/auth/me", headers={
        "Authorization": f"Bearer {completed.json()['session']}"
    }).status_code == 200
    assert client.post("/auth/verification/complete", json={"ticket": ticket}).status_code == 409

    response = client.post("/auth/login", json={"email": email, "password": password})
    assert response.status_code == 200
    session = response.json()["session"]
    headers = {"Authorization": f"Bearer {session}"}
    profile = client.get("/auth/me", headers=headers)
    assert profile.status_code == 200
    assert profile.json()["email_verified"] is True

    older_login = client.post("/auth/login", json={"email": email, "password": password})
    older_headers = {"Authorization": f"Bearer {older_login.json()['session']}"}

    setup = client.post("/auth/2fa/setup", headers=headers)
    assert setup.status_code == 200
    secret = setup.json()["secret"]
    enabled = client.post("/auth/2fa/enable", headers=headers,
                          json={"code": pyotp.TOTP(secret).now()})
    assert enabled.status_code == 200
    recovery_codes = enabled.json()["recovery_codes"]
    assert len(recovery_codes) == 8
    assert client.get("/auth/me", headers=headers).status_code == 200
    assert client.get("/auth/me", headers=older_headers).status_code == 401

    two_factor_prompt = client.post("/auth/login", json={"email": email, "password": password})
    assert two_factor_prompt.status_code == 428
    assert two_factor_prompt.json()["detail"] == "Zwei-Faktor-Code erforderlich."
    signed_in = client.post("/auth/login", json={
        "email": email, "password": password, "totp_code": pyotp.TOTP(secret).now()
    })
    assert signed_in.status_code == 200
    recovered = client.post("/auth/login", json={
        "email": email, "password": password, "totp_code": recovery_codes[0]
    })
    assert recovered.status_code == 200
    assert client.post("/auth/login", json={
        "email": email, "password": password, "totp_code": recovery_codes[0]
    }).status_code == 401
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
    assert client.post("/mcp", json={
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": "set_destination", "arguments": {"query": "Hochheim"}},
    }).status_code == 401


def test_mcp_reports_remote_command_completion(tmp_path, monkeypatch):
    monkeypatch.setenv("KIES_DRIVE_DB", str(tmp_path / "remote-status.db"))
    verification = {}
    monkeypatch.setattr(
        main, "send_verification_email",
        lambda email, token: verification.update(email=email, token=token),
    )
    main.AUTH_ATTEMPTS.clear()
    client = TestClient(main.app)
    email = "remote@example.com"
    password = "a-secure-remote-password"
    assert client.post("/auth/register", json={"email": email, "password": password}).status_code == 202
    assert client.get("/auth/verify-email", params={"token": verification["token"]}).status_code == 200
    session = client.post("/auth/login", json={"email": email, "password": password}).json()["session"]
    headers = {"Authorization": f"Bearer {session}"}

    queued = client.post("/mcp", headers=headers, json={
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": "set_destination", "arguments": {"query": "Hochheim"}},
    }).json()
    queued_data = json.loads(queued["result"]["content"][0]["text"])
    command_id = queued_data["command_id"]
    assert queued_data == {"accepted": True, "command_id": command_id, "status": "pending"}

    pending = client.post("/mcp", headers=headers, json={
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {"name": "get_command_status", "arguments": {"command_id": command_id}},
    }).json()
    pending_data = json.loads(pending["result"]["content"][0]["text"])
    assert pending_data["found"] is True
    assert pending_data["status"] == "pending"
    assert pending_data["result"] is None

    assert client.post(
        f"/api/navigation/remote/commands/{command_id}/complete",
        headers=headers, json={"ok": False, "message": "Route nicht verfügbar"},
    ).status_code == 200
    failed = client.post("/mcp", headers=headers, json={
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "get_command_status", "arguments": {"command_id": command_id}},
    }).json()
    failed_data = json.loads(failed["result"]["content"][0]["text"])
    assert failed_data["status"] == "failed"
    assert failed_data["result"] == {"ok": False, "message": "Route nicht verfügbar"}


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


def test_mcp_oauth_pkce_browser_login(tmp_path, monkeypatch):
    monkeypatch.setenv("KIES_DRIVE_DB", str(tmp_path / "oauth.db"))
    monkeypatch.setenv("KIES_DRIVE_PUBLIC_URL", "https://drive.example.test")
    verification = {}
    monkeypatch.setattr(main, "send_verification_email",
                        lambda email, token: verification.update(email=email, token=token))
    main.AUTH_ATTEMPTS.clear()
    client = TestClient(main.app)
    challenge_response = client.post("/mcp", json={
        "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}
    })
    assert challenge_response.status_code == 401
    assert "oauth-protected-resource" in challenge_response.headers["www-authenticate"]
    email, password = "mcp@example.com", "a-secure-mcp-password"
    client.post("/auth/register", json={"email": email, "password": password})
    client.get("/auth/verify-email", params={"token": verification["token"]})

    registered = client.post("/oauth/register", json={
        "client_name": "ChatGPT", "redirect_uris": ["https://chatgpt.com/connector/callback"]
    })
    assert registered.status_code == 201
    client_id = registered.json()["client_id"]
    verifier = "v" * 64
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    authorize = client.get("/oauth/authorize", params={
        "response_type": "code", "client_id": client_id,
        "redirect_uri": "https://chatgpt.com/connector/callback",
        "code_challenge": challenge, "code_challenge_method": "S256", "state": "safe-state",
    })
    assert authorize.status_code == 200
    nonce = re.search(r'name="nonce" value="([^"]+)"', authorize.text).group(1)
    approved = client.post("/oauth/authorize", data={
        "nonce": nonce, "email": email, "password": password, "totp_code": ""
    }, follow_redirects=False)
    assert approved.status_code == 303
    redirect = urlparse(approved.headers["location"])
    query = parse_qs(redirect.query)
    assert query["state"] == ["safe-state"]

    token = client.post("/oauth/token", data={
        "grant_type": "authorization_code", "client_id": client_id,
        "redirect_uri": "https://chatgpt.com/connector/callback",
        "code": query["code"][0], "code_verifier": verifier,
    })
    assert token.status_code == 200
    access_token = token.json()["access_token"]
    initialized = client.post("/mcp", headers={"Authorization": f"Bearer {access_token}"}, json={
        "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}
    })
    assert initialized.status_code == 200
    assert initialized.json()["result"]["serverInfo"]["name"] == "kies-drive"
    assert client.post("/oauth/token", data={
        "grant_type": "authorization_code", "client_id": client_id,
        "redirect_uri": "https://chatgpt.com/connector/callback",
        "code": query["code"][0], "code_verifier": verifier,
    }).status_code == 400
