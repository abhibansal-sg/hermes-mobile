"""Phase 1 gate: the phone driver speaks stock frames through the relay."""

from __future__ import annotations

import os
from pathlib import Path
from urllib.parse import quote

import httpx
import pytest

from mock_gateway.server import E2E_TOKEN
from phone_driver import PhoneDriver

pytestmark = pytest.mark.asyncio


async def test_stock_frames_round_trip_unchanged(
    mock_gateway, relay_subprocess, evidence
):
    phone = PhoneDriver(
        f"ws://127.0.0.1:{relay_subprocess.downstream_port}"
        f"/api/ws?token={E2E_TOKEN}"
    )
    await phone.connect()
    try:
        await phone.wait_for_event("gateway.ready")
        created = await phone.call(
            "session.create", {"title": "simple", "cols": 80, "source": "mobile"}
        )
        sid = created["result"]["session_id"]
        submitted = await phone.call(
            "prompt.submit", {"session_id": sid, "text": "stock proxy"}
        )
        assert "error" not in submitted
        complete = await phone.wait_for_event("message.complete", timeout=10)
        upstream = next(
            row for row in reversed(mock_gateway.event_log)
            if row.get("type") == "message.complete" and row.get("session_id") == sid
        )
        assert complete["params"] == {
            key: value for key, value in upstream.items() if key != "t"
        }

        async with httpx.AsyncClient() as client:
            history = await client.get(
                f"http://127.0.0.1:{relay_subprocess.downstream_port}"
                f"/api/sessions/{sid}/messages",
                headers={"X-Hermes-Session-Token": E2E_TOKEN},
            )
        history.raise_for_status()
        assert history.json()["session_id"] == sid
        evidence("stock-proxy", {
            "session_id": sid,
            "rpc_methods": [entry["method"] for entry in phone.sent],
            "event_types": [entry["params"]["type"] for entry in phone.events],
            "history_messages": len(history.json()["messages"]),
            "legacy_frames_seen": phone.legacy_frames_seen,
        })
        assert phone.legacy_frames_seen == 0
    finally:
        await phone.close()


async def test_external_stock_gateway_9130_plus(evidence):
    """Opt-in proof against a real isolated fork gateway, never port 9119."""
    ws_base = os.environ.get("ABH519_STOCK_PROXY_WS")
    http_base = os.environ.get("ABH519_STOCK_PROXY_HTTP")
    token_file = os.environ.get("ABH519_STOCK_PROXY_TOKEN_FILE")
    if not (ws_base and http_base and token_file):
        pytest.skip("external isolated-gateway proxy is not configured")

    token = Path(token_file).read_text(encoding="utf-8").strip()
    assert ":9119" not in ws_base and ":9119" not in http_base
    phone = PhoneDriver(f"{ws_base}/api/ws?token={quote(token, safe='')}")
    await phone.connect()
    try:
        await phone.wait_for_event("gateway.ready")
        active = await phone.call("session.active_list", {})
        assert "error" not in active
        created = await phone.call(
            "session.create",
            {"title": "ABH-519 Phase 1 proxy proof", "cols": 80, "source": "mobile"},
        )
        assert "error" not in created
        result = created["result"]
        stored_id = result.get("stored_session_id") or result["session_id"]
        async with httpx.AsyncClient() as client:
            status = await client.get(
                f"{http_base}/api/status",
                headers={"X-Hermes-Session-Token": token},
            )
        status.raise_for_status()
        evidence("external-stock-proxy", {
            "gateway_port_isolated": True,
            "ready_event": True,
            "active_list_result": "result" in active,
            "created_runtime_id": result["session_id"],
            "created_stored_id": stored_id,
            "http_status": status.status_code,
            "legacy_frames_seen": phone.legacy_frames_seen,
        })
        assert phone.legacy_frames_seen == 0
    finally:
        await phone.close()
