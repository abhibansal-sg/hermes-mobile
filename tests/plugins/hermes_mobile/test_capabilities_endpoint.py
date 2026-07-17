from __future__ import annotations


def test_capabilities_advertise_only_implemented_versioned_contracts():
    from fastapi.testclient import TestClient

    from hermes_cli.web_server import _SESSION_HEADER_NAME, _SESSION_TOKEN, app

    client = TestClient(app)
    client.headers[_SESSION_HEADER_NAME] = _SESSION_TOKEN
    response = client.get("/api/plugins/hermes-mobile/capabilities")

    assert response.status_code == 200, response.text
    assert response.json() == {
        "schema_version": 1,
        "sync_manifest": 2,
        "turn_projection": 1,
        "turn_detail": 0,
        "stable_assets": 1,
        "conditional_mutations": 0,
    }


def test_capabilities_fail_closed_without_public_turn_prerequisites(monkeypatch):
    from fastapi.testclient import TestClient

    from hermes_cli.web_server import _SESSION_HEADER_NAME, _SESSION_TOKEN, app
    from hermes_state import SessionDB

    monkeypatch.delattr(SessionDB, "get_turn_operations")
    client = TestClient(app)
    client.headers[_SESSION_HEADER_NAME] = _SESSION_TOKEN
    response = client.get("/api/plugins/hermes-mobile/capabilities")

    assert response.status_code == 200, response.text
    assert response.json()["turn_projection"] == 0
