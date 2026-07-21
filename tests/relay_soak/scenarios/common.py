"""Shared scenario helpers: deterministic reference runs + reconcile/compare.

Every durability scenario (T1/T2/T3/T4/T5/T7/T8) proves I2 the same way:

1. run a deterministic script CLEAN through a fresh phone -> reference items;
2. run the SAME script UNDER TORTURE (churn/flap/kill/gateway-abuse/ring) ->
   candidate items, reconciling by ``item_id`` exactly as the iOS store does;
3. require ``diff_transcripts(ref, cand)["identical"]``.

The helpers here keep that recipe identical across scenarios. Both gateway
backends expose ``async create_session(script=…, **kw) -> sid`` so the same code
drives the in-process mock and the signal-able subprocess gateway.
"""

from __future__ import annotations

import asyncio
from typing import Any, Optional

from tests.relay_soak.invariants.transcript import (  # noqa: F401
    agent_messages,
    diff_transcripts,
    reconcile_transcript,
    transcript_hash,
    user_message_ids,
)

# Deterministic default prompts (the scripted gateway's fixed outputs). A
# scenario may override ``text`` but must use the SAME text for its clean
# reference and its tortured run so the transcripts are comparable.
DEFAULT_TEXT = {
    "simple": "Paris is the capital of France.",
}


async def drive(
    phone: Any,
    gateway: Any,
    *,
    script: str = "simple",
    text: Optional[str] = None,
    sid: Optional[str] = None,
    client_message_id: Optional[str] = None,
    create_kwargs: Optional[dict[str, Any]] = None,
    timeout: float = 30.0,
) -> dict[str, Any]:
    """Create (or reuse) a scripted session, submit one turn, await a terminal
    frame, and return ``{sid, cmid, submit_response}``.

    ``gateway`` is an InProcGateway or SoakGatewayProc (both have
    ``async create_session``). If ``sid`` is given the turn drives that existing
    session instead of creating one.
    """
    if sid is None:
        kw = dict(create_kwargs or {})
        if text is not None:
            kw.setdefault("text", text)
        sid = await gateway.create_session(script=script, **kw)

    submit = await phone.submit(
        text=text or DEFAULT_TEXT.get(script, "soak turn"),
        session_id=sid,
        client_message_id=client_message_id,
    )
    result = (submit or {}).get("result") or {}
    resolved = result.get("session_id") or sid
    # Wait for the turn to reach a terminal frame on this phone.
    await wait_terminal(phone, resolved, timeout=timeout)
    return {"sid": resolved, "cmid": client_message_id, "submit_response": result}


async def wait_terminal(phone: Any, sid: str, *, timeout: float = 30.0) -> None:
    """Block until a ``turn.completed`` (or error item) lands for ``sid``."""
    try:
        await phone.wait_for(
            "turn.completed", sid=sid, timeout=timeout,
        )
    except asyncio.TimeoutError:
        # A turn that errors completes via an error item, not turn.completed.
        await phone.wait_for(
            "item.completed", sid=sid, timeout=2.0,
            predicate=lambda f: (f.body or {}).get("type") == "error",
        )


async def reconcile_after_settle(
    phone: Any, sid: str, *, resync_from: Optional[int] = 0, settle_s: float = 0.3
) -> dict[str, dict[str, Any]]:
    """Optionally resync, let stragglers land, then reconcile the transcript.

    ``resync_from=0`` forces a cold snapshot (heals any gap before we compare);
    ``resync_from=None`` skips the resync (the phone is already caught up).
    """
    if resync_from is not None:
        try:
            await phone.resync(resync_from)
        except Exception:  # noqa: BLE001
            pass
    await asyncio.sleep(settle_s)
    return reconcile_transcript(phone.frames_for(sid))


async def run_reference(
    phone: Any, gateway: Any, *, script: str = "simple",
    text: Optional[str] = None, create_kwargs: Optional[dict[str, Any]] = None,
) -> dict[str, dict[str, Any]]:
    """A CLEAN run of ``script`` -> the canonical reconciled transcript."""
    info = await drive(phone, gateway, script=script, text=text,
                       create_kwargs=create_kwargs)
    return await reconcile_after_settle(phone, info["sid"], resync_from=None)
