import base64
import hashlib
import json
import re
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs, urlparse

import pyotp
import pytest
from fastapi.testclient import TestClient

import app.main as main


def test_production_readiness_discloses_no_secrets(monkeypatch):
    async def search_is_ready(_url):
        return _url is not None

    monkeypatch.setattr(main, "searxng_is_ready", search_is_ready)
    monkeypatch.delenv("KIES_DRIVE_PUBLIC_URL", raising=False)
    monkeypatch.delenv("SMTP_HOST", raising=False)
    monkeypatch.delenv("SMTP_FROM", raising=False)
    monkeypatch.delenv("SEARXNG_URL", raising=False)
    client = TestClient(main.app)

    missing = client.get("/readyz")
    assert missing.status_code == 503
    assert missing.json()["checks"] == {
        "public_https": False,
        "email_delivery": False,
        "toll_research": False,
    }

    monkeypatch.setenv("KIES_DRIVE_PUBLIC_URL", "https://drive.example.test")
    monkeypatch.setenv("SMTP_HOST", "smtp.example.test")
    monkeypatch.setenv("SMTP_FROM", "Kies Drive <drive@example.test>")
    monkeypatch.setenv("SEARXNG_URL", "http://searxng:8080/")
    monkeypatch.setenv("SMTP_PASSWORD", "must-never-be-returned")
    ready = client.get("/readyz")
    assert ready.status_code == 200
    assert ready.json()["ok"] is True
    assert "must-never-be-returned" not in ready.text


def test_production_readiness_fails_when_toll_search_is_offline(monkeypatch):
    async def search_is_offline(_url):
        return False

    monkeypatch.setattr(main, "searxng_is_ready", search_is_offline)
    monkeypatch.setenv("KIES_DRIVE_PUBLIC_URL", "https://drive.example.test")
    monkeypatch.setenv("SMTP_HOST", "smtp.example.test")
    monkeypatch.setenv("SMTP_FROM", "Kies Drive <drive@example.test>")
    monkeypatch.setenv("SEARXNG_URL", "http://searxng:8080")

    response = TestClient(main.app).get("/readyz")

    assert response.status_code == 503
    assert response.json()["checks"]["toll_research"] is False


def test_searxng_configuration_accepts_only_http_urls(monkeypatch):
    monkeypatch.setenv("SEARXNG_URL", "http://searxng:8080/")
    assert main.configured_searxng_url() == "http://searxng:8080"
    monkeypatch.setenv("SEARXNG_URL", "searxng:8080")
    assert main.configured_searxng_url() is None


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
    assert main.explicit_toll_amount_and_currency("Mautkosten: 42,50 CHF") == (42.5, "CHF")
    assert main.explicit_toll_amount_and_currency("19.90 GBP toll costs") == (19.9, "GBP")


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


def test_toll_evidence_never_corroborates_different_currencies():
    year = main.date.today().year
    euro = {
        "title": f"Basel nach Zürich Gesamtmaut: 20 EUR {year}",
        "snippet": "", "url": "https://routes.example/trip",
    }
    francs = {
        "title": f"Basel nach Zürich Mautkosten: 20 CHF {year}",
        "snippet": "", "url": "https://prices.example.net/trip",
    }
    assert main.verified_toll_evidence([euro, francs], "Basel", "Zürich", []) is None

    second_francs = {
        "title": f"20 CHF Gesamtmaut Basel Zürich {year}",
        "snippet": "", "url": "https://tolls.example.org/trip",
    }
    evidence = main.verified_toll_evidence(
        [francs, second_francs], "Basel", "Zürich", []
    )
    assert evidence is not None
    assert evidence[:2] == (20.0, "CHF")


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
    assert not main.toll_source_is_current(old, official=True, current_year=2026)
    assert main.toll_source_is_current(
        "ASFINAG Gesamtmaut 27,40 EUR Split Hochheim 2026",
        official=True, current_year=2026,
    )
    assert main.verified_toll_evidence(
        sources, "Split", "Hochheim am Main", ["Wurzenpass"]
    ) is None


def test_toll_evidence_must_match_actual_route_variant():
    text = "Split nach Hochheim über Wurzenpass auf der A10, Gesamtmaut 24 EUR 2026"
    assert main.toll_source_matches_route(
        text, "Split", "Hochheim", ["Wurzenpass"], ["A10", "E55"]
    )
    assert not main.toll_source_matches_route(
        text, "Split", "Hochheim", ["Wurzenpass"], ["A2", "E59"]
    )


def test_toll_search_rejects_malformed_searxng_json(monkeypatch):
    class FakeResponse:
        def raise_for_status(self):
            return None

        def json(self):
            return ["valid JSON, wrong shape"]

    class FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, traceback):
            return False

        async def get(self, *args, **kwargs):
            return FakeResponse()

    monkeypatch.setenv("SEARXNG_URL", "http://searxng:8080")
    monkeypatch.setattr(main, "current_user", lambda authorization: {"id": 1})
    monkeypatch.setattr(main.httpx, "AsyncClient", FakeAsyncClient)

    response = TestClient(main.app).post(
        "/api/navigation/toll-search",
        json={"origin": "Split", "destination": "Hochheim", "via": ["Wurzenpass"]},
        headers={"Authorization": "Bearer test"},
    )

    assert response.status_code == 502
    assert response.json()["detail"] == "SearXNG ist gerade nicht erreichbar."


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
    assert queued_data == {
        "accepted": True, "command_id": command_id, "status": "pending",
        "deduplicated": False, "superseded_commands": 0,
    }

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


def test_mcp_rejects_invalid_navigation_mutations_before_queueing(tmp_path, monkeypatch):
    monkeypatch.setenv("KIES_DRIVE_DB", str(tmp_path / "remote-validation.db"))
    verification = {}
    monkeypatch.setattr(
        main, "send_verification_email",
        lambda email, token: verification.update(email=email, token=token),
    )
    main.AUTH_ATTEMPTS.clear()
    client = TestClient(main.app)
    email, password = "validation@example.com", "a-secure-validation-password"
    client.post("/auth/register", json={"email": email, "password": password})
    client.get("/auth/verify-email", params={"token": verification["token"]})
    session = client.post("/auth/login", json={"email": email, "password": password}).json()["session"]
    headers = {"Authorization": f"Bearer {session}"}

    invalid_calls = [
        ("set_destination", {}),
        ("set_destination", {"latitude": 50}),
        ("set_destination", {"query": "Hochheim", "required_waypoints": [
            {"latitude": 100, "longitude": 8}
        ]}),
        ("set_route_options", {}),
        ("add_route_stop", {"query": " "}),
    ]
    for index, (name, arguments) in enumerate(invalid_calls, start=1):
        response = client.post("/mcp", headers=headers, json={
            "jsonrpc": "2.0", "id": index, "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        }).json()
        assert response["result"]["isError"] is True

    with main.db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM user_commands").fetchone()[0] == 0


def test_remote_command_queue_deduplicates_retries_and_supersedes_old_route_intent(
        tmp_path, monkeypatch):
    monkeypatch.setenv("KIES_DRIVE_DB", str(tmp_path / "commands.db"))
    now = main.datetime(2026, 10, 19, tzinfo=main.timezone.utc)
    with main.db() as conn:
        conn.execute(
            "INSERT INTO users(email,password_hash,email_verified_at,created_at) VALUES(?,?,?,?)",
            ("queue@example.com", "unused", now.isoformat(), now.isoformat()),
        )
        user_id = conn.execute("SELECT id FROM users").fetchone()["id"]

        first, duplicate, superseded = main.enqueue_remote_command(
            conn, user_id, "add_route_stop", {"query": "McDonalds"}, now
        )
        retried, was_duplicate, retry_superseded = main.enqueue_remote_command(
            conn, user_id, "add_route_stop", {"query": "McDonalds"}, now
        )
        assert retried == first
        assert duplicate is False
        assert was_duplicate is True
        assert superseded == retry_superseded == 0

        destination, was_duplicate, superseded = main.enqueue_remote_command(
            conn, user_id, "set_destination", {"query": "Hochheim"}, now
        )
        assert destination != first
        assert was_duplicate is False
        assert superseded == 1
        old = conn.execute(
            "SELECT status,result FROM user_commands WHERE id=?", (first,)
        ).fetchone()
        assert old["status"] == "superseded"
        assert "neueres Remote-Ziel" in json.loads(old["result"])["message"]
        pending = conn.execute(
            "SELECT command FROM user_commands WHERE user_id=? AND status='pending'",
            (user_id,),
        ).fetchall()
        assert [row["command"] for row in pending] == ["set_destination"]


def test_remote_command_queue_is_bounded_while_phone_is_offline(tmp_path, monkeypatch):
    monkeypatch.setenv("KIES_DRIVE_DB", str(tmp_path / "bounded.db"))
    now = main.datetime(2026, 10, 19, tzinfo=main.timezone.utc)
    monkeypatch.setattr(main, "REMOTE_PENDING_COMMAND_LIMIT", 2)
    with main.db() as conn:
        conn.execute(
            "INSERT INTO users(email,password_hash,email_verified_at,created_at) VALUES(?,?,?,?)",
            ("bounded@example.com", "unused", now.isoformat(), now.isoformat()),
        )
        user_id = conn.execute("SELECT id FROM users").fetchone()["id"]
        main.enqueue_remote_command(conn, user_id, "add_route_stop", {"query": "A"}, now)
        main.enqueue_remote_command(conn, user_id, "add_route_stop", {"query": "B"}, now)
        with pytest.raises(main.HTTPException) as error:
            main.enqueue_remote_command(conn, user_id, "add_route_stop", {"query": "C"}, now)
        assert error.value.status_code == 429


def test_stale_remote_command_expires_without_reaching_phone(tmp_path, monkeypatch):
    monkeypatch.setenv("KIES_DRIVE_DB", str(tmp_path / "remote-expiry.db"))
    verification = {}
    monkeypatch.setattr(
        main, "send_verification_email",
        lambda email, token: verification.update(email=email, token=token),
    )
    main.AUTH_ATTEMPTS.clear()
    client = TestClient(main.app)
    email, password = "expiry@example.com", "a-secure-expiry-password"
    client.post("/auth/register", json={"email": email, "password": password})
    client.get("/auth/verify-email", params={"token": verification["token"]})
    session = client.post("/auth/login", json={"email": email, "password": password}).json()["session"]
    headers = {"Authorization": f"Bearer {session}"}
    queued = client.post("/mcp", headers=headers, json={
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": "set_destination", "arguments": {"query": "Hochheim"}},
    }).json()
    command_id = json.loads(queued["result"]["content"][0]["text"])["command_id"]
    stale_time = datetime.now(timezone.utc) - main.REMOTE_COMMAND_MAX_AGE - timedelta(seconds=1)
    with main.db() as conn:
        conn.execute("UPDATE user_commands SET created_at=? WHERE id=?",
                     (stale_time.isoformat(), command_id))

    assert client.get("/api/navigation/remote/commands", headers=headers).json() == {"commands": []}
    status = client.post("/mcp", headers=headers, json={
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {"name": "get_command_status", "arguments": {"command_id": command_id}},
    }).json()
    data = json.loads(status["result"]["content"][0]["text"])
    assert data["status"] == "expired"
    assert data["result"]["ok"] is False


def test_remote_state_freshness_uses_device_recording_time_not_database_write():
    now = datetime(2026, 10, 18, 12, 0, tzinfo=timezone.utc)
    stale_recording = now - timedelta(minutes=2)
    just_stored = now - timedelta(seconds=1)

    recorded_at, age, live = main.remote_state_freshness(
        {"recorded_at": stale_recording.isoformat()}, just_stored.isoformat(), now=now
    )

    assert recorded_at == stale_recording.isoformat()
    assert age == 120
    assert live is False


def test_remote_state_freshness_rejects_materially_future_device_clock():
    now = datetime(2026, 10, 18, 12, 0, tzinfo=timezone.utc)
    _, age, live = main.remote_state_freshness(
        {"recorded_at": (now + timedelta(seconds=30)).isoformat()},
        now.isoformat(), now=now,
    )
    assert age == 0
    assert live is False


def test_remote_state_payload_is_bounded_and_mcp_safe():
    encoded = main.encode_remote_state({"speed_kmh": 82, "recorded_at": "2026-10-18T12:00:00Z"})
    assert main.decode_remote_state(encoded)["speed_kmh"] == 82
    assert main.decode_remote_state("not-json") == {}
    assert main.decode_remote_state("[]") == {}

    try:
        main.encode_remote_state(["not", "an", "object"])
        assert False, "A non-object snapshot must be rejected"
    except main.HTTPException as exc:
        assert exc.status_code == 422

    try:
        main.encode_remote_state({"oversized": "x" * main.MAX_REMOTE_STATE_BYTES})
        assert False, "An oversized snapshot must be rejected"
    except main.HTTPException as exc:
        assert exc.status_code == 413


def test_active_route_mcp_view_exposes_navigation_reliability():
    state = {
        "active_route": {"destination": "Hochheim"},
        "route_lock": {"title": "Kroatien"},
        "navigation_active": True,
        "on_route": False,
        "rerouting": True,
        "offline_guidance_active": False,
    }
    view = main.active_route_remote_view(state)

    assert view["navigation_active"] is True
    assert view["on_route"] is False
    assert view["rerouting"] is True
    assert view["offline_guidance_active"] is False


def test_heading_and_maneuver_views_are_human_readable_and_safety_aware():
    assert main.heading_remote_view({"heading_degrees": 0}) == {
        "degrees": 0.0, "direction": "Nord"
    }
    assert main.heading_remote_view({"heading_degrees": 91}) == {
        "degrees": 91.0, "direction": "Ost"
    }
    assert main.heading_remote_view({"heading_degrees": 315}) == {
        "degrees": 315.0, "direction": "Nordwest"
    }
    assert main.heading_remote_view({"heading_degrees": float("nan")}) is None

    view = main.next_maneuver_remote_view({
        "next_maneuver": None,
        "navigation_active": True,
        "on_route": False,
        "rerouting": True,
        "offline_guidance_active": False,
    })
    assert view == {
        "next_maneuver": None,
        "navigation_active": True,
        "on_route": False,
        "rerouting": True,
        "offline_guidance_active": False,
    }


def test_stale_live_telemetry_is_withheld_but_persistent_route_remains_visible():
    state = {
        "location": {"latitude": 50.0, "longitude": 8.0},
        "heading_degrees": 91,
        "speed_kmh": 130,
        "next_maneuver": {"instruction": "Rechts abbiegen"},
        "active_route": {"destination": "Hochheim"},
        "route_lock": {"title": "Urlaubsfahrt"},
        "navigation_active": True,
    }

    for name in ("get_location", "get_heading", "get_speed", "get_next_maneuver"):
        assert main.remote_tool_value(name, state, live=False) is None

    route = main.remote_tool_value("get_active_route", state, live=False)
    assert route["active_route"]["destination"] == "Hochheim"
    assert route["route_lock"]["title"] == "Urlaubsfahrt"

    assert main.remote_tool_value("get_speed", state, live=True) == 130
    assert main.remote_tool_value("get_heading", state, live=True) == {
        "degrees": 91.0,
        "direction": "Ost",
    }


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
    monkeypatch.setenv("KIES_DRIVE_PUBLIC_URL", "https://drive.example.test/kies-drive")
    verification = {}
    monkeypatch.setattr(main, "send_verification_email",
                        lambda email, token: verification.update(email=email, token=token))
    main.AUTH_ATTEMPTS.clear()
    client = TestClient(main.app)
    challenge_response = client.post("/mcp", json={
        "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}
    })
    assert challenge_response.status_code == 401
    assert challenge_response.headers["www-authenticate"] == (
        'Bearer resource_metadata="https://drive.example.test/'
        '.well-known/oauth-protected-resource/kies-drive/mcp"'
    )
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


def test_well_known_urls_insert_before_path_components():
    assert main.well_known_url(
        "https://drive.example.test/kies-drive", "oauth-authorization-server"
    ) == "https://drive.example.test/.well-known/oauth-authorization-server/kies-drive"
    assert main.well_known_url(
        "https://drive.example.test/kies-drive/mcp", "oauth-protected-resource"
    ) == "https://drive.example.test/.well-known/oauth-protected-resource/kies-drive/mcp"
