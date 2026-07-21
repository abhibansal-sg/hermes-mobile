"""Transcript reconstruction + reference diff (I2 / I4 shared core).

The relay is stateless on the wire; the phone rebuilds its transcript by folding
the downstream frame stream, honoring the **completed-is-authoritative** rule
(RELAY-PHONE-PROTOCOL.md §2/§4):

* ``snapshot``        — its ``items`` are authoritative (replace by item_id);
* ``item.started``    — inserts the item skeleton;
* ``item.delta``      — NON-authoritative (skipped; completed wins);
* ``item.completed``  — replaces the item wholesale.

This is exactly the fold the iOS ``RelayItemStore`` paints and the fold
``tests/e2e_daily_driver/test_f_ws_flap_chaos.py`` uses to assert byte-identity.
Factored here so every soak scenario reconciles identically.

I2 ("byte-identical reconcile") is then: reconcile a CLEAN reference run of a
deterministic script, reconcile a TORTURED run of the SAME script, and require
the agent transcript to be identical (same items, same authoritative bodies).
"""

from __future__ import annotations

import hashlib
import json
from typing import Any, Iterable

# Frame kinds (string literals keep this module decoupled from hermes_relay so
# it runs against ANY relay source the harness is pointed at).
_SNAPSHOT = "snapshot"
_ITEM_STARTED = "item.started"
_ITEM_DELTA = "item.delta"
_ITEM_COMPLETED = "item.completed"


def reconcile_transcript(frames: Iterable[Any]) -> dict[str, dict[str, Any]]:
    """Fold a frame stream into ``{item_id: item}`` (completed authoritative).

    ``frames`` are objects with ``.kind`` and ``.body`` (PhoneFrame-shaped) OR
    plain dicts — both are accepted so this works on recorded logs too.
    """
    items: dict[str, dict[str, Any]] = {}
    for f in frames:
        kind = f.kind if hasattr(f, "kind") else f.get("kind")
        body = f.body if hasattr(f, "body") else f.get("body")
        body = body or {}
        if kind == _SNAPSHOT:
            for it in body.get("items", []):
                items[it["item_id"]] = it
        elif kind == _ITEM_STARTED:
            items[body["item_id"]] = body
        elif kind == _ITEM_DELTA:
            continue  # non-authoritative; completed replaces
        elif kind == _ITEM_COMPLETED:
            items[body["item_id"]] = body
    return items


def _item_hash(item: dict[str, Any]) -> str:
    """Stable hash of an item's user-visible content (drops per-run ids).

    ``item_id`` embeds the session id and ``ord`` is an allocation counter —
    both differ across runs of the same script, so they are excluded. The hash
    covers exactly what the user sees: type/status/summary/body.
    """
    payload = {k: v for k, v in item.items() if k not in ("item_id", "ord")}
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, default=str).encode("utf-8")
    ).hexdigest()


def transcript_hash(items: dict[str, dict[str, Any]]) -> str:
    """One stable hash for a whole reconciled transcript (order-independent)."""
    hashes = sorted(_item_hash(it) for it in items.values())
    return hashlib.sha256("|".join(hashes).encode("utf-8")).hexdigest()


def agent_messages(items: dict[str, dict[str, Any]]) -> list[str]:
    """The authoritative agentMessage texts, in ``ord`` order."""
    msgs = [it for it in items.values() if it.get("type") == "agentMessage"]
    msgs.sort(key=lambda it: it.get("ord", 0))
    return [str((it.get("body") or {}).get("text", "")) for it in msgs]


def user_message_ids(frames: Iterable[Any], sid: str | None = None) -> set[str]:
    """Distinct item_ids of completed ``userMessage`` items (I4 dedup probe).

    A single logical prompt must land on exactly ONE item_id no matter how many
    resyncs/replays/duplicate-submits happened. >1 distinct id == duplication.
    """
    ids: set[str] = set()
    for f in frames:
        kind = f.kind if hasattr(f, "kind") else f.get("kind")
        body = f.body if hasattr(f, "body") else f.get("body")
        fsid = f.sid if hasattr(f, "sid") else f.get("sid")
        body = body or {}
        if sid is not None and fsid != sid:
            continue
        if kind == _ITEM_COMPLETED and body.get("type") == "userMessage":
            ids.add(body.get("item_id", ""))
    return ids


def diff_transcripts(
    ref: dict[str, dict[str, Any]], cand: dict[str, dict[str, Any]],
    *, exclude_types: frozenset[str] = frozenset({"userMessage"}),
) -> dict[str, Any]:
    """Structured comparison of a candidate transcript against a reference.

    Returns ``{identical, hash_match, comparable_hash_match, ref_agent,
    cand_agent, missing_types, extra_types, …}`` for evidence. Content-keyed
    (not item_id-keyed) so a deterministic script run under torture compares
    equal to a clean run.

    ``userMessage`` is EXCLUDED from the cross-run hash by default: the relay
    embeds the per-submit ``client_message_id`` in the userMessage body, so two
    runs of the same script intentionally carry different userMessage bodies
    (mirrors test_f_ws_flap_chaos.py's exemption). UserMessage integrity is I4's
    job (exactly-one-id-per-prompt), not I2's. ``identical`` is therefore the
    AGENT transcript: agent texts match AND the non-excluded items hash-match.
    """
    def _comparable(items: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
        return {k: v for k, v in items.items()
                if v.get("type") not in exclude_types}

    ref_cmp = _comparable(ref)
    cand_cmp = _comparable(cand)

    ref_types = sorted({it.get("type") for it in ref.values()})
    cand_types = sorted({it.get("type") for it in cand.values()})

    ref_agent = agent_messages(ref)
    cand_agent = agent_messages(cand)

    comparable_hash_match = transcript_hash(ref_cmp) == transcript_hash(cand_cmp)
    ref_by_hash = {_item_hash(it) for it in ref_cmp.values()}
    cand_by_hash = {_item_hash(it) for it in cand_cmp.values()}

    return {
        "identical": comparable_hash_match and ref_agent == cand_agent,
        "hash_match": transcript_hash(ref) == transcript_hash(cand),
        "comparable_hash_match": comparable_hash_match,
        "ref_agent": ref_agent,
        "cand_agent": cand_agent,
        "missing_types": sorted(set(ref_types) - set(cand_types)),
        "extra_types": sorted(set(cand_types) - set(ref_types)),
        "ref_item_count": len(ref),
        "cand_item_count": len(cand),
        "cand_only_hashes": sorted(cand_by_hash - ref_by_hash),
        "ref_only_hashes": sorted(ref_by_hash - cand_by_hash),
    }
