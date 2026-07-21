"""Upstream conformance (phone -> relay): A2/N1 structural kill.

Asserts, from LIVE sources (not copies):

* the method sets agree across all three surfaces (Swift ``RelayUpstreamMethod``
  enum, relay ``UpstreamMethod.ALL``, shared fixture);
* every param key an iOS ``RelayClient`` builder sends is READ by the relay's
  ``handle_upstream`` (nothing the phone sends falls on the floor);
* every param the relay REQUIRES (``p["k"]`` — a miss raises) is sent by iOS;
* the fixture's declared sends/reads match both live surfaces (anti-rot);
* BEHAVIORALLY: the payload iOS actually builds for each method drives
  ``handle_upstream`` with no silent failure and lands the right gateway RPC
  with the right MAPPED params (decision->choice, text->answer, prompt->text).

This is the test class that FAILS on the prompt/text, decision/choice,
text/answer bug family: e.g. an iOS approve that sends ``approved`` instead of
``decision`` trips ``test_ios_shaped_payloads_drive_relay_without_silent_failure``
(KeyError on the relay side -> JSON-RPC -32000 -> silent-deny on the phone).
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import extract  # noqa: E402


# ---------------------------------------------------------------------------
# Static: three-surface agreement
# ---------------------------------------------------------------------------


def _relay_ahead(contract) -> dict:
    """The R4 Wave-1 ratchet (relay-first surfaces awaiting iOS glue).

    ROUND4-LEAN-PLAN.md §c sequencing: the relay lanes deploy ONCE, ahead of
    the iOS waves (additive; old iOS unaffected). A method the relay
    implements before its iOS builder exists lives in ``relay_ahead.methods``
    instead of ``upstream.payloads``: the relay surface is held to it (the
    reads/behavioral tests below cover it), while the Swift surface still
    equals ``upstream.payloads`` exactly — so the XCTest consumer (which reads
    ``upstream.payloads`` alone) stays green until the iOS adoption lane. The
    section MUST be empty at the Wave-4 exit (relay-only tree).
    """
    return dict(contract.get("relay_ahead", {}).get("methods", {}))


def test_upstream_method_sets_agree_across_all_surfaces(contract):
    swift = set(extract.swift_upstream_methods())
    from hermes_relay.types import UpstreamMethod

    relay = set(UpstreamMethod.ALL)
    fixture = set(contract["upstream"]["payloads"])
    ahead = set(_relay_ahead(contract))
    assert swift == fixture, (
        f"Swift RelayUpstreamMethod != fixture: "
        f"swift-only={swift - fixture}, fixture-only={fixture - swift}"
    )
    assert relay == fixture | ahead, (
        f"relay UpstreamMethod.ALL != fixture + relay_ahead: "
        f"relay-only={relay - fixture - ahead}, "
        f"declared-only={fixture | ahead - relay}"
    )
    # RATCHET (double-acting): a relay_ahead method Swift has ALREADY adopted
    # is a stale entry — this fails the moment the iOS builder lands, forcing
    # the adopter to MOVE the spec into upstream.payloads and delete it from
    # relay_ahead (the XCTest method-set equality then holds again naturally).
    adopted = swift & ahead
    assert not adopted, (
        f"iOS now implements {sorted(adopted)} — MOVE each spec from "
        f"relay_ahead.methods into upstream.payloads (with real ios_sends) "
        f"and DELETE it from relay_ahead (R4 Wave-1 ratchet; the section must "
        f"be empty at the Wave-4 exit)"
    )


def test_relay_ahead_specs_are_pending_not_phantom(contract):
    """Hygiene for the ratchet: a relay_ahead method is relay-real (present in
    UpstreamMethod.ALL), genuinely pre-adoption (no iOS sends declared), and
    fully specified (example + gateway mapping for the behavioral tests)."""
    from hermes_relay.types import UpstreamMethod

    for method, spec in _relay_ahead(contract).items():
        assert method in UpstreamMethod.ALL, (
            f"relay_ahead.{method} is not in UpstreamMethod.ALL — a phantom, "
            f"not a relay-first surface"
        )
        assert spec["ios_sends"] == {"required": [], "optional": []}, (
            f"relay_ahead.{method} declares ios_sends — an adopted method "
            f"belongs in upstream.payloads, not the ratchet"
        )
        assert spec.get("example"), f"relay_ahead.{method} has no example payload"


def test_fixture_ios_sends_match_swift_builders(contract):
    swift = extract.swift_upstream_sends()
    for method, spec in contract["upstream"]["payloads"].items():
        want = spec["ios_sends"]
        got = swift.get(method, {"required": [], "optional": []})
        assert got["required"] == sorted(want["required"]), (
            f"{method}: iOS REQUIRED sends drifted. Swift builds {got['required']}, "
            f"contract says {sorted(want['required'])}"
        )
        assert got["optional"] == sorted(want["optional"]), (
            f"{method}: iOS OPTIONAL sends drifted. Swift builds {got['optional']}, "
            f"contract says {sorted(want['optional'])}"
        )


def test_fixture_relay_reads_match_downstream_ast(contract):
    reads = extract.relay_upstream_reads()
    # The relay side is held to the FULL surface — adopted methods AND the
    # relay_ahead ratchet entries (the relay implements those already).
    specs = dict(contract["upstream"]["payloads"])
    specs.update(_relay_ahead(contract))
    for method, spec in specs.items():
        want = spec["relay_reads"]
        got = reads.get(method, {"required": [], "optional": []})
        assert got["required"] == sorted(want["required"]), (
            f"{method}: relay REQUIRED reads drifted. handle_upstream reads "
            f"{got['required']} as p[...], contract says {sorted(want['required'])}"
        )
        assert got["optional"] == sorted(want["optional"]), (
            f"{method}: relay OPTIONAL reads drifted. handle_upstream reads "
            f"{got['optional']} via p.get, contract says {sorted(want['optional'])}"
        )


def test_every_ios_sent_field_is_read_by_relay(contract):
    """R4: nothing the phone sends may fall on the floor (the silent-failure class)."""
    for method, spec in contract["upstream"]["payloads"].items():
        reads = set(spec["relay_reads"]["required"]) | set(spec["relay_reads"]["optional"])
        aliased = set()
        for a, b in spec.get("aliases", []):
            aliased.add(a)
            aliased.add(b)
        for key in set(spec["ios_sends"]["required"]) | set(spec["ios_sends"]["optional"]):
            assert key in reads or key in aliased, (
                f"{method}: iOS sends '{key}' but the relay handle_upstream never "
                f"reads it (reads {sorted(reads)}) — the field is silently dropped"
            )


def test_every_relay_required_field_is_sent_by_ios(contract):
    """R5: a relay ``p["k"]`` the phone never sends is a guaranteed KeyError ->
    JSON-RPC -32000 -> the phone sees an opaque failure (the silent-deny class)."""
    for method, spec in contract["upstream"]["payloads"].items():
        sends = set(spec["ios_sends"]["required"]) | set(spec["ios_sends"]["optional"])
        alias_of: dict[str, set[str]] = {}
        for a, b in spec.get("aliases", []):
            alias_of.setdefault(a, set()).update({a, b})
            alias_of.setdefault(b, set()).update({a, b})
        for key in spec["relay_reads"]["required"]:
            satisfied = key in sends or bool(alias_of.get(key, set()) & sends)
            assert satisfied, (
                f"{method}: relay requires p['{key}'] but iOS never sends it "
                f"(iOS sends {sorted(sends)}) — every such call raises KeyError"
            )


def test_envelope_agrees(contract):
    swift = set(extract.swift_rpc_request_envelope())
    fixture = set(contract["upstream"]["envelope"]["request"])
    assert swift == fixture, (
        f"JSONRPCRequest envelope drifted: Swift {sorted(swift)} vs fixture {sorted(fixture)}"
    )
    # The relay's UpstreamRequest.from_wire reads method/params/id off that envelope.
    from hermes_relay.types import UpstreamRequest

    req = UpstreamRequest.from_wire({"jsonrpc": "2.0", "id": 1, "method": "list", "params": {}})
    assert req.method == "list" and req.params == {} and req.id == 1


# ---------------------------------------------------------------------------
# Behavioral: the real iOS shape drives the relay, end-to-end, unmapped
# ---------------------------------------------------------------------------


def _drive(server, conn, method, params):
    from hermes_relay.types import UpstreamRequest

    req = UpstreamRequest.from_wire(
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    )
    return asyncio.run(server.handle_upstream(conn, req))


def test_ios_shaped_payloads_drive_relay_without_silent_failure(server_stack, contract):
    """Build each method's payload from the keys the SWIFT BUILDER actually emits
    (live-extracted) and drive the real ``handle_upstream``. Any field the relay
    requires but the phone doesn't send raises here — this is the structural
    kill for the approve/clarify/submit bug class."""
    server, conn, gateway = server_stack
    sends = extract.swift_upstream_sends()
    for method, spec in contract["upstream"]["payloads"].items():
        keys = set(sends[method]["required"]) | set(sends[method]["optional"])
        missing_samples = keys - set(_sample_values().keys())
        assert not missing_samples, (
            f"{method}: conformance SAMPLE_VALUES lacks {sorted(missing_samples)}; "
            f"extend conftest.SAMPLE_VALUES"
        )
        params = {k: _sample_values()[k] for k in keys}
        # A KeyError/TypeError here == the relay demands a field iOS never sends.
        try:
            _drive(server, conn, method, params)
        except (KeyError, TypeError) as exc:
            raise AssertionError(
                f"{method}: iOS-shaped payload {sorted(keys)} BREAKS the relay: "
                f"{exc!r}. The phone's builder and the relay handler disagree on "
                f"the wire contract (the silent-failure bug class)."
            ) from exc
        # Request-kind methods must actually reach the gateway (no silent no-op).
        if spec["expect_gateway"]:
            assert gateway.calls, f"{method}: expected a gateway hop, none recorded"

    # relay_ahead methods have no Swift builder yet — drive the fixture EXAMPLE
    # through the real handler with the same silent-failure kill.
    for method, spec in _relay_ahead(contract).items():
        try:
            _drive(server, conn, method, dict(spec["example"]))
        except (KeyError, TypeError) as exc:
            raise AssertionError(
                f"{method} (relay_ahead): example payload {sorted(spec['example'])} "
                f"BREAKS the relay: {exc!r}."
            ) from exc
        if spec["expect_gateway"]:
            assert gateway.calls, f"{method}: expected a gateway hop, none recorded"


def test_fixture_examples_map_to_the_right_gateway_params(server_stack, contract):
    """The semantic mapping: decision->choice, text->answer, prompt->text. A
    regression that sends the phone's key straight through (or drops it) fails."""
    # Adopted methods first, then the relay_ahead ratchet entries (their
    # examples drive last, so the per-RPC recorded params are theirs).
    specs = dict(contract["upstream"]["payloads"])
    specs.update(_relay_ahead(contract))
    for method, spec in specs.items():
        if not spec["expect_gateway"]:
            continue
        server, conn, gateway = server_stack
        _drive(server, conn, method, dict(spec["example"]))
        recorded = dict(gateway.calls)
        for expect in spec["expect_gateway"]:
            rpc = expect["rpc"]
            assert rpc in recorded, (
                f"{method}: expected gateway RPC {rpc}, recorded {list(recorded)}"
            )
            if "params" in expect:
                for key, value in expect["params"].items():
                    assert recorded[rpc].get(key) == value, (
                        f"{method} -> {rpc}: param '{key}' = {recorded[rpc].get(key)!r}, "
                        f"contract says {value!r} (full call: {recorded[rpc]})"
                    )
            for key, value in expect.get("params_include", {}).items():
                assert recorded[rpc].get(key) == value, (
                    f"{method} -> {rpc}: param '{key}' = {recorded[rpc].get(key)!r}, "
                    f"expected to include {value!r}"
                )


def test_history_limit_is_honored(server_stack, contract):
    """iOS history sends an optional ``limit``; the relay must READ it (A2: every
    sent field is read) and bound the reply to the most recent N messages."""
    server, conn, gateway = server_stack
    result = _drive(server, conn, "history", {"session_id": "sess-1", "limit": 50})
    messages = result["messages"]
    assert len(messages) == 50, (
        f"history: relay returned {len(messages)} messages for limit=50 "
        f"(gateway has {len(gateway._history)}) — the phone's limit is being dropped"
    )
    assert messages == gateway._history[-50:], (
        "history: limit must keep the MOST RECENT messages (tail), not the head"
    )


def test_local_control_frames_work(server_stack, contract):
    """ack/resync/foreground/push.* are relay-local; they must consume their
    params and never touch the gateway."""
    server, conn, gateway = server_stack
    for method in ("ack", "resync", "foreground"):
        params = dict(contract["upstream"]["payloads"][method]["example"])
        _drive(server, conn, method, params)
    # foreground{session_id} registers the session for the §6 notification gate.
    assert server.session_has_live_phone("sess-1")
    _drive(server, conn, "foreground", {"session_id": None})
    assert not server.session_has_live_phone("sess-1")
    # §6a (QA-1 B14): push.register/push.unregister are relay-local too — the
    # token lands in the relay's OWN registry (the one the Notifier reads) and
    # unregister removes it; neither hops the gateway.
    example = dict(contract["upstream"]["payloads"]["push.register"]["example"])
    result = _drive(server, conn, "push.register", example)
    assert result == {"registered": True}
    token = example["token"]
    push = server._push_engine()
    assert token in push.registered_tokens()
    result = _drive(server, conn, "push.unregister", {"token": token})
    assert result == {"unregistered": True}
    assert token not in push.registered_tokens()
    assert not gateway.calls, "local control frames must never hit the gateway"


def _sample_values():
    from conftest import SAMPLE_VALUES

    return SAMPLE_VALUES
