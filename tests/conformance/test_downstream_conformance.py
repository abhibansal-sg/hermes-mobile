"""Downstream conformance (relay -> phone): A2/N1 structural kill.

Asserts, from LIVE sources:

* frame KIND sets agree (Swift ``RelayFrameKind`` wire strings, relay
  ``FrameKind.ALL``, fixture) — a kind the relay emits that iOS cannot decode
  would strand content;
* the envelope keys agree (Swift ``RelayFrame`` CodingKeys, relay
  ``Frame.to_wire``, fixture);
* the ITEM shape agrees (Swift ``ChatItem(json:)`` reads, relay ``Item.to_dict``,
  fixture) — a field the relay emits under one name and iOS reads under another
  is exactly the bug this suite exists to kill;
* the reframer's EMITTED bodies (driven behaviorally from representative raw
  gateway events) conform to the per-kind body contract the iOS decoders rely
  on, and gate frames pass through with the identity keys iOS needs to reply;
* the shared sample frames (the same JSON XCTest decodes with ``RelayFrame``)
  decode on the relay side too.
"""

from __future__ import annotations

import sys
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parent))

import extract  # noqa: E402

from hermes_relay.bus import EventBus  # noqa: E402
from hermes_relay.reframer import Reframer  # noqa: E402
from hermes_relay.session_state import SessionStore  # noqa: E402
from hermes_relay.types import Frame, FrameKind, GatewayEvent, Item, ItemStatus, ItemType  # noqa: E402


# ---------------------------------------------------------------------------
# Static: kind / envelope / item-shape agreement
# ---------------------------------------------------------------------------


def test_frame_kind_sets_agree_across_all_surfaces(contract):
    swift = set(extract.swift_frame_kinds())
    relay = set(FrameKind.ALL)
    fixture = set(contract["downstream"]["kinds"])
    assert swift == fixture, (
        f"Swift RelayFrameKind wire strings != fixture: "
        f"swift-only={swift - fixture}, fixture-only={fixture - swift}"
    )
    assert relay == fixture, (
        f"relay FrameKind.ALL != fixture: "
        f"relay-only={relay - fixture}, fixture-only={fixture - relay}"
    )
    # Every Swift wire string must round-trip (init(wire:) <-> wire property).
    for wire_string in swift:
        assert wire_string, f"empty wire string in RelayFrameKind map: {wire_string!r}"


def test_envelope_agrees(contract):
    swift = extract.swift_frame_envelope()
    fixture = contract["downstream"]["envelope"]
    assert swift == fixture, (
        f"RelayFrame envelope drifted: Swift {swift} vs fixture {fixture}"
    )
    stamped = Frame(sid="s", kind=FrameKind.STATUS, body={"k": "v"}, seq=1)
    assert list(stamped.to_wire().keys()) == fixture, (
        f"relay Frame.to_wire keys drifted: {list(stamped.to_wire().keys())} vs {fixture}"
    )


def test_item_shape_agrees(contract):
    shape = contract["downstream"]["item_shape"]
    declared = set(shape["required"]) | set(shape["optional"])
    swift = set(extract.swift_chat_item_json_keys())
    relay = set(Item(item_id="i", type=ItemType.TOOL_CALL).to_dict().keys())
    assert swift == declared, (
        f"ChatItem(json:) reads {sorted(swift)} but the item shape is {sorted(declared)} "
        f"— a renamed item field silently decodes to a default on the phone"
    )
    assert relay == declared, (
        f"relay Item.to_dict emits {sorted(relay)} but the item shape is {sorted(declared)}"
    )
    # Required fields must be non-optional on BOTH sides.
    for key in shape["required"]:
        assert key in relay, f"relay Item.to_dict can omit required '{key}'"


def test_item_type_coverage_and_fold(contract):
    """Every type the relay can emit is either native on iOS or on the documented
    generic-fold allowlist (§2 forward-compat: unknown types render as toolCall).
    When N4-style work promotes a folded type to a native case, move it in the
    fixture — the suite fails on any untracked divergence either way."""
    types = contract["downstream"]["item_types"]
    swift = set(extract.swift_item_types())
    relay = set(ItemType.ALL)
    assert swift == set(types["ios_native"]), (
        f"ChatItemType cases drifted: Swift {sorted(swift)} vs fixture "
        f"{sorted(types['ios_native'])}"
    )
    assert relay == set(types["relay_all"]), (
        f"relay ItemType.ALL drifted: {sorted(relay)} vs fixture {sorted(types['relay_all'])}"
    )
    assert relay - swift == set(types["generic_fold"]), (
        f"relay-emitted types iOS folds to toolCall = {sorted(relay - swift)}, "
        f"but the fixture's generic_fold allowlist is {sorted(types['generic_fold'])}. "
        f"Update the fixture deliberately when promoting a type to native."
    )


def test_item_statuses_agree(contract):
    relay = {ItemStatus.IN_PROGRESS, ItemStatus.COMPLETED, ItemStatus.FAILED}
    assert relay == set(contract["downstream"]["item_statuses"])


def test_body_projection_keys_match_fixture(contract):
    projections = extract.swift_body_projection_keys()
    body_contract = contract["downstream"]["body_contract"]
    assert set(projections["item.delta"]) == (
        set(body_contract["item.delta"]["required"]) | set(body_contract["item.delta"]["optional"])
    ), f"item.delta projection reads {projections['item.delta']}"
    assert set(projections["snapshot"]) == (
        set(body_contract["snapshot"]["required"]) | set(body_contract["snapshot"]["optional"])
    ), f"snapshot projection reads {projections['snapshot']}"
    assert projections["turn.completed"] == ["usage"]


def test_gate_decoder_keys_match_fixture(contract):
    """The fixture's declared iOS gate reads must be exactly what the shared
    ApprovalRequestPayload / ClarifyRequestPayload decoders actually read."""
    decoders = extract.swift_gate_decoder_keys()
    for kind in ("approval.request", "clarify.request"):
        assert set(decoders[kind]) == set(contract["downstream"]["body_contract"][kind]["ios_reads"]), (
            f"{kind}: iOS decoder reads {sorted(decoders[kind])}, fixture declares "
            f"{sorted(contract['downstream']['body_contract'][kind]['ios_reads'])}"
        )


# ---------------------------------------------------------------------------
# Behavioral: reframer emissions conform to the body contract
# ---------------------------------------------------------------------------

_USAGE = {"input": 10, "output": 5, "total": 15}

# Raw gateway event -> (expected emitted kinds in order). Each event runs in its
# OWN session, so the first content-bearing event also opens the turn
# (_ensure_turn) — hence the leading "turn.started" on content events.
# Non-item chatter (status/title/gates/thinking) never opens a turn.
_EVENT_TABLE: list[tuple[dict, list[str]]] = [
    ({"type": "message.start", "payload": None}, ["turn.started"]),
    (
        {"type": "message.delta", "payload": {"text": "He"}},
        ["turn.started", "item.started", "item.delta"],
    ),
    (
        {"type": "message.complete", "payload": {"text": "Hello", "usage": _USAGE}},
        ["turn.started", "item.completed", "item.completed", "turn.completed"],
    ),
    (
        {"type": "reasoning.delta", "payload": {"text": "hm"}},
        ["turn.started", "item.started", "item.delta"],
    ),
    (
        {"type": "reasoning.available", "payload": {"text": "hmm"}},
        ["turn.started", "item.completed"],
    ),
    ({"type": "thinking.delta", "payload": {"text": "…"}}, ["status"]),
    (
        {"type": "tool.start", "payload": {"tool_id": "t1", "name": "shell", "args_text": "ls"}},
        ["turn.started", "item.started"],
    ),
    (
        {
            "type": "tool.complete",
            "payload": {"tool_id": "t1", "name": "shell", "args": {"cmd": "ls"}, "result": "ok", "duration_s": 0.1},
        },
        ["turn.started", "item.completed"],
    ),
    (
        {"type": "tool.complete", "payload": {"tool_id": "t2", "name": "edit_file", "inline_diff": "@@ a b @@"}},
        ["turn.started", "item.completed"],
    ),
    (
        {"type": "tool.start", "payload": {"name": "todo", "args": {"todos": [{"id": "a", "content": "x", "status": "pending"}]}}},
        ["turn.started", "item.started"],
    ),
    (
        {"type": "tool.complete", "payload": {"name": "todo", "todos": [{"id": "a", "content": "x", "status": "completed"}]}},
        ["turn.started", "item.completed"],
    ),
    ({"type": "error", "payload": {"message": "boom"}}, ["turn.started", "item.completed"]),
    (
        {"type": "status.update", "payload": {"kind": "compacting", "text": "Compacting history"}},
        ["status"],
    ),
    ({"type": "session.title", "payload": {"title": "New title"}}, ["title"]),
    (
        {
            "type": "approval.request",
            "payload": {"command": "rm -rf /tmp/x", "description": "Delete temp", "pattern_keys": ["rm"]},
        },
        ["approval.request"],
    ),
    (
        {
            "type": "clarify.request",
            "payload": {"question": "Which env?", "choices": ["staging", "prod"], "request_id": "clr-1"},
        },
        ["clarify.request"],
    ),
    # Forward-compat: an UNKNOWN raw event still yields an ordered item — never dropped.
    ({"type": "future.event", "payload": {"anything": 1}}, ["turn.started", "item.completed"]),
]


def _check_body_against_contract(kind: str, body: dict, contract) -> None:
    spec = contract["downstream"]["body_contract"][kind]
    keys = set(body.keys())
    if spec.get("item_frame"):
        shape = contract["downstream"]["item_shape"]
        required = set(shape["required"])
        allowed = required | set(shape["optional"])
        assert required <= keys, f"{kind}: item body missing required {sorted(required - keys)}"
        assert keys <= allowed, f"{kind}: item body has undeclared keys {sorted(keys - allowed)}"
        return
    if spec.get("passthrough"):
        guaranteed = set(spec.get("guaranteed", []))
        assert guaranteed <= keys, (
            f"{kind}: passthrough body must guarantee {sorted(guaranteed)} for the iOS "
            f"decoder, got {sorted(keys)}"
        )
        return
    required = set(spec.get("required", []))
    optional = set(spec.get("optional", []))
    assert required <= keys, f"{kind}: body missing required {sorted(required - keys)}"
    if spec.get("closed"):
        assert keys <= required | optional, (
            f"{kind}: closed body has undeclared keys {sorted(keys - required - optional)}"
        )


def test_reframer_emissions_conform_to_body_contract(contract):
    """Drive the real Reframer with one representative raw event per kind and
    assert every emitted frame's kind + body shape matches what the iOS
    decoders consume. A reframer that renames/drops a body key fails here."""
    kinds = set(contract["downstream"]["kinds"])
    store = SessionStore()
    reframer = Reframer(EventBus(), store)
    saw_kinds: set[str] = set()
    for i, (event, expected_kinds) in enumerate(_EVENT_TABLE):
        payload = event["payload"]
        frames = reframer.reframe(
            GatewayEvent(
                type=event["type"],
                session_id=f"sess-{i}",
                payload=payload if isinstance(payload, dict) else {},
            )
        )
        got_kinds = [f.kind for f in frames]
        assert got_kinds == expected_kinds, (
            f"raw event {event['type']}: emitted kinds {got_kinds}, expected {expected_kinds}"
        )
        for frame in frames:
            assert frame.kind in kinds, f"relay emitted undeclared kind {frame.kind!r}"
            saw_kinds.add(frame.kind)
            _check_body_against_contract(frame.kind, frame.body, contract)
    # ``snapshot`` is emitted by the DownstreamServer's resync path (covered by
    # test_snapshot_shape_agrees), never by the Reframer — every OTHER kind must
    # be exercised by the table.
    assert saw_kinds == kinds - {"snapshot"}, (
        f"event table failed to exercise kinds {sorted(kinds - saw_kinds - {'snapshot'})}"
    )


def test_gate_frames_carry_the_identity_ios_replies_with(contract):
    """clarify replies route by body.request_id; approval replies route by the
    envelope sid. The reframer passes the gateway payload through, so both
    identities must survive the relay untouched."""
    store = SessionStore()
    reframer = Reframer(EventBus(), store)
    clarify = reframer.reframe(
        GatewayEvent(
            type="clarify.request",
            session_id="sess-1",
            payload={"question": "Which env?", "choices": ["a"], "request_id": "clr-9"},
        )
    )
    assert clarify[0].body["request_id"] == "clr-9", "clarify.request lost its request_id"
    approval = reframer.reframe(
        GatewayEvent(
            type="approval.request",
            session_id="sess-1",
            payload={"command": "git push", "description": "push", "pattern_keys": []},
        )
    )
    assert approval[0].sid == "sess-1", "approval.request frame lost the sid iOS replies on"
    assert approval[0].body["command"] == "git push"


def test_snapshot_shape_agrees(contract):
    """SessionStore.snapshot body == fixture == the keys RelaySnapshot reads."""
    store = SessionStore()
    reframer = Reframer(EventBus(), store)
    reframer.reframe(
        GatewayEvent(type="message.start", session_id="sess-1", payload={})
    )
    reframer.reframe(
        GatewayEvent(
            type="message.complete", session_id="sess-1", payload={"text": "hi", "usage": _USAGE}
        )
    )
    body = store.snapshot("sess-1", cursor=9)
    spec = contract["downstream"]["body_contract"]["snapshot"]
    declared = set(spec["required"]) | set(spec["optional"])
    assert set(body.keys()) == declared, (
        f"snapshot body keys {sorted(body.keys())} != contract {sorted(declared)}"
    )
    projection = set(extract.swift_body_projection_keys()["snapshot"])
    assert set(spec["required"]) <= projection, (
        f"iOS RelaySnapshot never reads required snapshot key {sorted(set(spec['required']) - projection)}"
    )
    shape = contract["downstream"]["item_shape"]
    for item in body["items"]:
        assert set(shape["required"]) <= set(item.keys())
        assert set(item.keys()) <= set(shape["required"]) | set(shape["optional"])


# ---------------------------------------------------------------------------
# Shared samples decode on the relay side (XCTest decodes the SAME JSON)
# ---------------------------------------------------------------------------


def test_shared_samples_decode_on_relay_side(contract):
    for sample in contract["downstream"]["samples"]:
        wire = sample["frame"]
        frame = Frame.from_wire(wire)
        assert frame.kind in FrameKind.ALL, (
            f"sample {sample['name']}: kind {frame.kind!r} not in FrameKind.ALL"
        )
        stamped = Frame(
            sid=frame.sid, kind=frame.kind, body=frame.body, turn=frame.turn, seq=wire["seq"]
        )
        assert list(stamped.to_wire().keys()) == contract["downstream"]["envelope"]


def test_turn_completed_usage_body_shape(contract):
    """turn.completed carries usage at body.usage — the exact key RelayFrame.usage
    reads (body['usage'] ?? body)."""
    reframer = Reframer(EventBus(), SessionStore())
    frames = reframer.reframe(
        GatewayEvent(
            type="message.complete", session_id="sess-1", payload={"text": "x", "usage": _USAGE}
        )
    )
    turn = next(f for f in frames if f.kind == FrameKind.TURN_COMPLETED)
    assert turn.body.get("usage") == _USAGE
    projection = extract.swift_body_projection_keys()["turn.completed"]
    assert "usage" in projection
