"""Gateway-edge conformance (relay -> gateway): the decision/choice + text/answer kill.

The stock gateway's ``approval.respond`` handler reads ``choice`` and DEFAULTS
it to ``deny`` — a relay that forwards the phone's ``decision`` key silently
denies every approval. ``clarify.respond`` stores ``params["answer"]`` — a
relay that forwards ``text`` delivers an EMPTY answer. These bugs shipped once
already (see the §5 table in docs/RELAY-PHONE-PROTOCOL.md). This suite asserts
the triangle from LIVE sources so they cannot ship again:

* ``gateway_client.py`` param dicts (ast-extracted) match the fixture's
  ``relay_sends``;
* the in-repo gateway handlers' ``params`` reads (ast-extracted from
  ``tui_gateway/server.py``) match the fixture's ``gateway_reads``;
* every key the relay sends is read by the gateway (nothing falls on the floor);
* the semantically EFFECTIVE keys (the ones with a silent default) are sent
  with the phone's value mapped onto them: ``choice`` for approvals, ``answer``
  for clarify, ``text`` for prompts.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import extract  # noqa: E402

# Keys the gateway reads but with a SILENT DEFAULT — the relay MUST send these
# (an absent key does not raise; it just does the wrong thing invisibly).
_EFFECTIVE_KEYS = {
    "prompt.submit": ["text"],          # default "" -> empty prompt
    "approval.respond": ["choice"],     # default "deny" -> silent denial
    "clarify.respond": ["answer"],      # default "" -> empty answer
}


def test_relay_gateway_client_sends_match_fixture(contract):
    sends = extract.relay_gateway_rpc_params()
    for rpc, spec in contract["gateway"]["rpcs"].items():
        got = sends.get(rpc)
        assert got is not None, f"gateway_client.py no longer issues {rpc}"
        want = spec["relay_sends"]
        assert got["required"] == sorted(want["required"]), (
            f"{rpc}: gateway_client always-sent params drifted: {got['required']} "
            f"vs contract {sorted(want['required'])}"
        )
        assert got["optional"] == sorted(want["optional"]), (
            f"{rpc}: gateway_client conditional params drifted: {got['optional']} "
            f"vs contract {sorted(want['optional'])}"
        )


def test_gateway_handler_reads_match_fixture(contract):
    reads = extract.gateway_handler_reads()
    for rpc, spec in contract["gateway"]["rpcs"].items():
        got = reads.get(rpc)
        assert got is not None, f"tui_gateway/server.py has no @method({rpc!r}) handler"
        got_keys = set(got["required"]) | set(got["optional"])
        want_keys = set(spec["gateway_reads"]["required"]) | set(spec["gateway_reads"]["optional"])
        assert got_keys == want_keys, (
            f"{rpc}: gateway handler reads {sorted(got_keys)}, contract declares "
            f"{sorted(want_keys)} — update the fixture deliberately if the gateway "
            f"surface changed"
        )


def test_every_relay_sent_key_is_read_by_gateway(contract):
    """A param the relay sends that the gateway never reads is a renamed-field
    bug in waiting (the decision/choice class): the gateway silently falls back
    to its default instead of the phone's value. The ONLY tolerated extras are
    the fixture's declared ``accepted_unread`` forward-compat keys — and those
    must never be an effective (silent-default) key."""
    reads = extract.gateway_handler_reads()
    for rpc, spec in contract["gateway"]["rpcs"].items():
        gateway_keys = set(reads[rpc]["required"]) | set(reads[rpc]["optional"])
        relay_keys = set(spec["relay_sends"]["required"]) | set(spec["relay_sends"]["optional"])
        accepted = set(spec.get("accepted_unread", []))
        assert not (accepted & set(_EFFECTIVE_KEYS.get(rpc, []))), (
            f"{rpc}: accepted_unread {sorted(accepted)} may not contain an effective "
            f"key — an unread effective key is exactly the silent-wrong-default bug"
        )
        unread = relay_keys - gateway_keys - accepted
        assert not unread, (
            f"{rpc}: relay sends {sorted(unread)} but the gateway handler never "
            f"reads them (reads {sorted(gateway_keys)}) and they are not declared "
            f"accepted_unread — those values are silently dropped"
        )


def test_effective_keys_with_silent_defaults_are_always_sent(contract):
    """The keys that DEFAULT to a wrong value when absent (choice->deny,
    answer->"", text->"") must be on the relay's ALWAYS-sent list, not a
    conditional one."""
    for rpc, effective in _EFFECTIVE_KEYS.items():
        spec = contract["gateway"]["rpcs"][rpc]
        for key in effective:
            assert key in spec["relay_sends"]["required"], (
                f"{rpc}: '{key}' has a silent wrong default at the gateway and is "
                f"NOT on the relay's always-sent list — the phone's value can be "
                f"dropped without any error surfacing"
            )


def test_phone_values_reach_the_effective_keys(contract):
    """End-to-end value mapping from the UPSTREAM contract: the phone's
    ``decision`` lands on the gateway's ``choice``, its ``text`` on ``answer``,
    its ``prompt`` on ``text``. Ties the upstream + gateway edges together."""
    upstream = contract["upstream"]["payloads"]

    approve = upstream["approve"]
    approval_rpc = next(e for e in approve["expect_gateway"] if e["rpc"] == "approval.respond")
    assert approval_rpc["params"]["choice"] == approve["example"]["decision"], (
        "approve: the phone's decision must map onto the gateway's choice param"
    )

    clarify = upstream["clarify"]
    clarify_rpc = next(e for e in clarify["expect_gateway"] if e["rpc"] == "clarify.respond")
    assert clarify_rpc["params"]["answer"] == clarify["example"]["text"], (
        "clarify: the phone's text must map onto the gateway's answer param"
    )

    submit = upstream["submit"]
    submit_rpc = next(e for e in submit["expect_gateway"] if e["rpc"] == "prompt.submit")
    assert submit_rpc["params"]["text"] == submit["example"]["prompt"], (
        "submit: the phone's prompt must map onto the gateway's text param"
    )
