"""Scenario (f) — 10× WS flap chaos mid-turn → byte-identical (A4).

A4 is the reconnect contract: "kill the WS 10× mid-turn → transcript reconciles
byte-identical to an undropped run (no doubled text, no lost items)".

The mechanism under test is the relay's seq/ack/replay ring + the
completed-is-authoritative rule (RELAY-PHONE-PROTOCOL.md §4). When the phone WS
flaps, the relay's per-connection ring evicts; on reconnect the phone resyncs
and either (a) gets a tail replay (small gap) or (b) gets a fresh snapshot
(large gap) — both of which reconcile by ``item_id`` and never double text.

We run the SAME deterministic script twice:

* ``clean`` — no flaps. Captures the canonical final item set.
* ``chaos`` — 10× WS close+reconnect+resync mid-stream.

Then we compare the canonical agentMessage text + taskList body reconciled in
each. They MUST byte-match: the user-visible transcript is identical, no matter
how many times the WS flapped underneath.
"""

from __future__ import annotations

import asyncio
import hashlib
import json

import pytest

pytestmark = pytest.mark.asyncio


def _hash_item(item: dict) -> str:
    """A stable hash of an item dict (the canonical body the user sees)."""
    # Order-independent: sort the keys. item_id is per-session, so drop it.
    payload = {k: v for k, v in item.items() if k not in ("item_id", "ord")}
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, default=str).encode("utf-8")
    ).hexdigest()


async def _final_items(phone, sid: str, *, timeout: float = 20.0) -> dict[str, dict]:
    """Reconcile every item.* + snapshot frame into a final item_id -> item map.

    ``completed`` is authoritative (protocol §2/§4) so a completed frame REPLACES
    any started/delta state for the same item_id; a snapshot's items are also
    authoritative. This is exactly what the iOS RelayItemStore does to paint.
    """
    deadline = asyncio.get_event_loop().time() + timeout
    items: dict[str, dict] = {}
    while asyncio.get_event_loop().time() < deadline:
        for f in phone.frames_for(sid):
            if f.kind == "snapshot":
                for it in f.body.get("items", []):
                    items[it["item_id"]] = it
            elif f.kind == "item.started":
                items[f.body["item_id"]] = f.body
            elif f.kind == "item.delta":
                # Non-authoritative; skip — completed wins.
                continue
            elif f.kind == "item.completed":
                items[f.body["item_id"]] = f.body
        # Done once we've seen a turn.completed for this sid.
        if any(f.kind == "turn.completed" and f.sid == sid for f in phone.frames):
            return items
        await asyncio.sleep(0.05)
    return items


async def test_ws_flap_chaos_byte_identical(mock_gateway, phone_factory, evidence):
    from mock_gateway.server import create_scripted_session

    # --- clean run: canonical transcript ---
    clean_sid = await create_scripted_session(
        mock_gateway, script="simple",
        text="Chaos runs must reconcile byte-identical.",
    )
    clean_phone = await phone_factory()
    await clean_phone.submit(text="Begin clean run", session_id=clean_sid)
    clean_items = await _final_items(clean_phone, clean_sid)
    clean_hashes = {
        it.get("type"): _hash_item(it)
        for it in clean_items.values()
    }
    clean_text = next(
        (it.get("body", {}).get("text", "")
         for it in clean_items.values() if it.get("type") == "agentMessage"),
        "",
    )
    assert clean_text == "Chaos runs must reconcile byte-identical.", (
        f"clean run did not complete cleanly: items={clean_items}"
    )

    # --- chaos run: 10× WS flap mid-stream ---
    # Use a long stream (delta_delay_s=0.12 → ~1.4s of streaming) so all 10
    # flaps at 80ms intervals land WHILE the turn is still streaming. Without
    # this the simple script completes in ~60ms and we only fit 1-2 flaps.
    chaos_sid = await create_scripted_session(
        mock_gateway, script="simple",
        text="Chaos runs must reconcile byte-identical.",
        delta_delay_s=0.18,
    )
    chaos_phone = await phone_factory()

    flap_count = 0
    target_flaps = 10
    stop = asyncio.Event()

    async def flap_loop():
        nonlocal flap_count
        # Close + reconnect + resync every ~80ms until either we've done 10
        # flaps or the turn has completed.
        while not stop.is_set() and flap_count < target_flaps:
            await asyncio.sleep(0.08)
            try:
                await chaos_phone.close()
            except Exception:
                pass
            # Rebuild the driver against the same relay downstream port.
            chaos_phone._url = chaos_phone._url  # unchanged; same relay
            await chaos_phone.connect()
            # Resync from the last seq we saw (might be 0 on a fresh socket).
            last_seq = max((f.seq for f in chaos_phone.frames), default=0)
            await chaos_phone.resync(last_seq=last_seq)
            flap_count += 1

    flap_task = asyncio.create_task(flap_loop())
    await asyncio.sleep(0.05)  # let the flap loop arm
    await chaos_phone.submit(text="Begin chaos run", session_id=chaos_sid)
    chaos_items = await _final_items(chaos_phone, chaos_sid, timeout=30.0)
    stop.set()
    try:
        await asyncio.wait_for(flap_task, timeout=5.0)
    except asyncio.TimeoutError:
        flap_task.cancel()

    chaos_hashes = {
        it.get("type"): _hash_item(it)
        for it in chaos_items.values()
    }
    chaos_text = next(
        (it.get("body", {}).get("text", "")
         for it in chaos_items.values() if it.get("type") == "agentMessage"),
        "",
    )

    # The user-visible transcript is byte-identical across clean and chaos runs.
    assert chaos_text == clean_text, (
        f"agentMessage text diverged:\n  clean={clean_text!r}\n  chaos={chaos_text!r}"
    )
    # Every item type the clean run produced also appears (no lost items), with
    # an identical authoritative body (no doubled/diverged text).
    for itype, h in clean_hashes.items():
        assert itype in chaos_hashes, f"chaos run lost a {itype} item"
        assert chaos_hashes[itype] == h, (
            f"{itype} item body diverged between clean and chaos runs"
        )

    # The chaos run actually flapped 10× — proves A4 holds under the spec's
    # stated "10× ws_flap" load, not just 1-2 flaps.
    assert flap_count == target_flaps, (
        f"chaos run only flapped {flap_count}× (target {target_flaps}) — "
        "the script must be slow enough for all 10 flaps to land mid-stream"
    )

    evidence("f-ws-flap-chaos", {
        "clean_session_id": clean_sid,
        "chaos_session_id": chaos_sid,
        "flap_count": flap_count,
        "target_flaps": target_flaps,
        "clean_text": clean_text,
        "chaos_text": chaos_text,
        "byte_identical": clean_text == chaos_text and clean_hashes == chaos_hashes,
        "clean_item_types": sorted(clean_hashes),
        "chaos_item_types": sorted(chaos_hashes),
        "clean_frames_seen": len(clean_phone.frames_for(clean_sid)),
        "chaos_frames_seen": len(chaos_phone.frames_for(chaos_sid)),
    })
