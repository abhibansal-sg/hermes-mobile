"""Scenario (h) — attach round-trip over the relay (B9 / A5).

On a relay-only reach the phone CANNOT make the gateway-REST
``POST /api/upload`` round-trip the direct attach flow depends on — that is
the structural half of B9. The ratified fix routes attachments THROUGH the
relay as inlined ``data:`` bytes (upstream ``attach`` method), which the relay
translates to the gateway's base64 RPCs:

* ``kind=file``  -> ``file.attach``   (materialises the file, returns an
  ``@file:`` ref the composer appends to the next prompt);
* ``kind=image`` -> ``image.attach_bytes`` (vision tile, no REST upload).

This test asserts the round-trip end-to-end, driven from the phone-driver
(the iOS ``RelayClient.attach`` wire shape):

* the relay accepts ``attach`` and stages the bytes on the gateway;
* the ``file.attach`` result's ``@file:`` ref rides the NEXT prompt.submit
  verbatim, the turn completes;
* an image attach stages identically and its prompt turn completes.

If the relay regressed to "unknown upstream method: 'attach'" (the qa1/base
state) every RPC here errors — exactly the failure mode B9/A5 closes.
"""

from __future__ import annotations

import base64

import pytest

pytestmark = pytest.mark.asyncio


# 1x1 transparent PNG (the smallest decodable image payload).
_PNG_1X1_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"
    "YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
)


async def test_file_attach_roundtrip_ref_rides_prompt(
    mock_gateway, phone_factory, evidence
):
    from mock_gateway.server import create_scripted_session

    sid = await create_scripted_session(mock_gateway, script="simple")
    phone = await phone_factory()

    # Drive the session first (mirrors the phone opening a chat: the relay
    # resumes + owns it, so the attach targets a live session).
    res = await phone.submit(text="hello", session_id=sid)
    assert "result" in res, f"submit failed: {res}"
    driven_sid = res["result"]["session_id"]
    first_completed = await phone.wait_for(
        "item.completed", sid=driven_sid, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage",
    )

    # Attach a tiny text file — inlined bytes, the relay-only-capable path.
    payload = base64.b64encode(b"hermes attach e2e payload\n").decode("ascii")
    data_url = f"data:text/plain;base64,{payload}"
    att = await phone.attach(
        kind="file", data_url=data_url, session_id=driven_sid, name="notes.txt",
    )
    assert "result" in att, f"attach failed: {att}"
    r = att["result"]
    assert r.get("attached") is True, f"attach not attached: {r}"
    assert r.get("session_id") == driven_sid, f"session drift: {r}"
    assert r.get("ref_text") == "@file:notes.txt", f"bad ref_text: {r}"

    # White-box: the gateway saw file.attach with the inlined bytes intact.
    rpc = next(
        (x for x in mock_gateway.rpc_log if x["method"] == "file.attach"), None
    )
    assert rpc is not None, "gateway never saw file.attach"
    assert rpc["params"]["session_id"] == driven_sid
    assert rpc["params"]["data_url"] == data_url, "bytes corrupted in transit"
    sess = mock_gateway.sessions[driven_sid]
    assert {"kind": "file", "name": "notes.txt", "data_url": data_url} in sess.attachments

    # The @file: ref rides the next prompt verbatim and the turn completes.
    res2 = await phone.submit(
        text="Summarize @file:notes.txt", session_id=driven_sid
    )
    assert "result" in res2, f"second submit failed: {res2}"
    # Seq-anchored: wait for the SECOND turn's completion, not the first's.
    completed = await phone.wait_for(
        "item.completed", sid=driven_sid, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage"
        and f.seq > first_completed.seq,
    )
    assert completed is not None
    last_prompt = mock_gateway.sessions[driven_sid].script.kwargs.get("last_prompt", "")
    assert "@file:notes.txt" in last_prompt, f"ref not on the wire: {last_prompt!r}"

    evidence("h-file-attach-roundtrip", {
        "session_id": driven_sid,
        "attach_result": r,
        "gateway_file_attach_params": rpc["params"],
        "prompt_with_ref": last_prompt,
    })


async def test_image_attach_roundtrip(mock_gateway, phone_factory, evidence):
    from mock_gateway.server import create_scripted_session

    sid = await create_scripted_session(mock_gateway, script="simple")
    phone = await phone_factory()

    res = await phone.submit(text="hello", session_id=sid)
    driven_sid = res["result"]["session_id"]
    first_completed = await phone.wait_for(
        "item.completed", sid=driven_sid, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage",
    )

    # Photo attach: inlined base64, NO POST /api/upload anywhere in the path.
    data_url = f"data:image/png;base64,{_PNG_1X1_B64}"
    att = await phone.attach(
        kind="image", data_url=data_url, session_id=driven_sid, name="dot.png",
    )
    assert "result" in att, f"image attach failed: {att}"
    r = att["result"]
    assert r.get("attached") is True, f"not attached: {r}"
    assert r.get("session_id") == driven_sid
    assert r.get("path", "").endswith("dot.png"), f"no staged path: {r}"

    rpc = next(
        (x for x in mock_gateway.rpc_log if x["method"] == "image.attach_bytes"),
        None,
    )
    assert rpc is not None, "gateway never saw image.attach_bytes"
    assert rpc["params"]["session_id"] == driven_sid
    assert rpc["params"]["content_base64"] == data_url

    # The default-caption send (the iOS image-with-no-caption prompt) completes
    # a turn on the session that now carries the attachment.
    res2 = await phone.submit(
        text="Please look at the attached image.", session_id=driven_sid
    )
    assert "result" in res2, f"submit failed: {res2}"
    completed = await phone.wait_for(
        "item.completed", sid=driven_sid, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage"
        and f.seq > first_completed.seq,
    )
    assert completed is not None

    evidence("h-image-attach-roundtrip", {
        "session_id": driven_sid,
        "attach_result": r,
        "gateway_image_attach_params_keys": sorted(rpc["params"].keys()),
    })
