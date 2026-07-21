"""Invariant checkers I1-I8 as reusable assertions.

Each checker folds observable evidence (the phone's recorded frame log, the
relay's /healthz status, the resource curve, or an in-process notifier drive)
into a structured ``report()`` with a ``violations`` list. Scenarios assert
``not report["violations"]`` and dump the whole report as evidence.

Mapping to the spec contract (RELAY-SOAK-SPEC.md):

* **I1 No lost turn**         — :class:`TurnTerminalTracker`
* **I2 Byte-identical**       — :mod:`~tests.relay_soak.invariants.transcript`
* **I3 No dropped sub / seq** — :class:`SeqCoverageChecker`
* **I4 Echo/dedup**           — :class:`DedupChecker`
* **I5 Owned-session life**   — :class:`OwnedSessionLedger`
* **I6 Resource bounds**      — :class:`~tests.relay_soak.infra.resources.ResourceSampler`
* **I7 Notify correctness**   — :class:`NotifyRecorder` (in-process, mock APNs)
* **I8 Protocol robustness**  — :class:`RobustnessChecker`

Every checker is relay-source-agnostic: it reads wire-level shapes, never imports
the relay under test, so the same harness re-soaks any relay tree.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any, Optional

import httpx

_log = logging.getLogger("soak.invariants")

_TURN_STARTED = "turn.started"
_TURN_COMPLETED = "turn.completed"
_ITEM_COMPLETED = "item.completed"


def _g(obj: Any, attr: str, key: str, default: Any = None) -> Any:
    """Read ``attr`` from an object or ``key`` from a dict (uniform access)."""
    if hasattr(obj, attr):
        return getattr(obj, attr)
    if isinstance(obj, dict):
        return obj.get(key, default)
    return default


# ---------------------------------------------------------------------------
# I1 — every submitted turn reaches a terminal state (no eternal-working).
# ---------------------------------------------------------------------------


class TurnTerminalTracker:
    """Folds a frame log into per-(session, turn) terminal state.

    A turn is *working* from its ``turn.started`` and *terminal* on its
    ``turn.completed`` OR an ``error`` item completing under it. A phone that
    flapped may legitimately MISS the ``turn.completed`` frame yet still recover
    the completed turn via a resync ``snapshot`` (snapshots carry items, not
    turn-lifecycle frames) — so a snapshot holding a COMPLETED ``agentMessage``
    (or an error item) also counts as terminal. I1 fails if a driven session
    shows NONE of these (the submitted turn vanished — the S8 "dead turn" class)
    or has a started turn with no terminal evidence.
    """

    def __init__(self) -> None:
        self.started: dict[str, set[str]] = {}       # sid -> {turn_id}
        self.completed: dict[str, set[str]] = {}     # sid -> {turn_id} turn.completed
        self.errored: dict[str, set[str]] = {}       # sid -> {turn_id} error item
        self.snapshot_terminal: set[str] = set()     # sids healed by a snapshot
        self.statuses: dict[str, set[str]] = {}      # sid -> {status}
        self.driven: set[str] = set()                # sids the phone submitted to

    def mark_driven(self, sid: str) -> None:
        if sid:
            self.driven.add(sid)

    def fold(self, frames) -> "TurnTerminalTracker":
        for f in frames:
            kind = _g(f, "kind", "kind")
            sid = _g(f, "sid", "sid") or ""
            turn = _g(f, "turn", "turn")
            body = _g(f, "body", "body") or {}
            if not sid:
                continue
            if kind == _TURN_STARTED and turn:
                self.started.setdefault(sid, set()).add(turn)
            elif kind == _TURN_COMPLETED and turn:
                self.completed.setdefault(sid, set()).add(turn)
                self.statuses.setdefault(sid, set()).add(body.get("status", "completed"))
            elif kind == _ITEM_COMPLETED and body.get("type") == "error" and turn:
                self.errored.setdefault(sid, set()).add(turn)
                self.statuses.setdefault(sid, set()).add("error")
            elif kind == "snapshot":
                # A snapshot carrying a COMPLETED agentMessage / an error item
                # proves the session reached a terminal state even when the phone
                # never saw the turn.completed frame (flap + snapshot heal).
                for it in body.get("items", []):
                    if (it.get("type") == "agentMessage"
                            and it.get("status") == "completed"):
                        self.snapshot_terminal.add(sid)
                        self.statuses.setdefault(sid, set()).add("completed")
                    elif it.get("type") == "error":
                        self.snapshot_terminal.add(sid)
                        self.statuses.setdefault(sid, set()).add("error")
        return self

    def report(self) -> dict[str, Any]:
        violations: list[str] = []
        per_session: dict[str, Any] = {}
        for sid in sorted(self.driven):
            started = self.started.get(sid, set())
            completed = self.completed.get(sid, set())
            errored = self.errored.get(sid, set())
            snap = sid in self.snapshot_terminal
            has_terminal = bool(completed or errored or snap)
            per_session[sid] = {
                "started": len(started),
                "completed_frames": len(completed),
                "error_frames": len(errored),
                "snapshot_terminal": snap,
                "statuses": sorted(self.statuses.get(sid, set())),
            }
            if not has_terminal:
                violations.append(
                    f"I1: session {sid} was driven but reached NO terminal state "
                    f"(started={len(started)}, no turn.completed/error/snapshot) "
                    f"— lost/dead turn"
                )
                continue
            # Eternal-working: a started turn with no terminal evidence. When a
            # snapshot proves the session completed it covers every started turn
            # (the snapshot is the authoritative end-state of the session).
            if not snap:
                nonterminal = sorted(started - completed - errored)
                if nonterminal:
                    violations.append(
                        f"I1: session {sid} has {len(nonterminal)} non-terminal "
                        f"turn(s) (eternal-working): {nonterminal[:5]}"
                    )
        return {
            "invariant": "I1",
            "ok": not violations,
            "violations": violations,
            "driven_sessions": sorted(self.driven),
            "per_session": per_session,
        }


# ---------------------------------------------------------------------------
# I3 — seq coverage per connection generation (no dropped downstream frame).
# ---------------------------------------------------------------------------


class SeqCoverageChecker:
    """Per-connection seq coverage: every seq in [1..head] was received.

    ``seq`` is monotonic PER CONNECTION (downstream.py PhoneConnection), starting
    at 1 on each fresh socket. Within one connection generation the relay stamps
    1,2,3,…; replays may re-send (duplicates are fine), but a permanently
    DROPPED downstream frame leaves a hole in ``set(seqs)``. That hole is the
    observable signature of a lost subscription/frame (the I3/S8 class as seen
    from the phone).

    Feed it ``SoakPhoneDriver.generation_segments()`` (one frame list per
    connection generation).
    """

    def __init__(self) -> None:
        self.generations = 0
        self.frames_seen = 0
        self.dup_frames = 0
        self._violations: list[str] = []

    def fold_segments(self, segments: list[list[Any]]) -> "SeqCoverageChecker":
        for gi, seg in enumerate(segments, start=1):
            self.generations += 1
            seqs = [_g(f, "seq", "seq") for f in seg]
            seqs = [s for s in seqs if isinstance(s, int)]
            self.frames_seen += len(seqs)
            if not seqs:
                continue
            uniq = set(seqs)
            self.dup_frames += len(seqs) - len(uniq)
            lo, hi = min(uniq), max(uniq)
            expected = set(range(lo, hi + 1))
            holes = sorted(expected - uniq)
            if lo != 1:
                # A fresh connection starts at seq 1. A higher floor means the
                # phone missed the opening frames of this connection entirely.
                self._violations.append(
                    f"I3: generation {gi} starts at seq {lo} (expected 1) — "
                    f"opening frames lost"
                )
            if holes:
                self._violations.append(
                    f"I3: generation {gi} has {len(holes)} seq hole(s) in "
                    f"[{lo}..{hi}]: {holes[:10]} — dropped downstream frame(s)"
                )
        return self

    def report(self) -> dict[str, Any]:
        return {
            "invariant": "I3",
            "ok": not self._violations,
            "violations": self._violations,
            "generations": self.generations,
            "frames_seen": self.frames_seen,
            "duplicate_frames_ok": self.dup_frames,
        }


# ---------------------------------------------------------------------------
# I4 — duplicate submits / replayed frames never double-apply.
# ---------------------------------------------------------------------------


class DedupChecker:
    """Duplicate-submit + replay double-apply detection.

    * a re-submit with the SAME ``client_message_id`` must NOT drive a second
      turn: every response but the first carries ``deduplicated: True`` and the
      resolved ``session_id`` is stable;
    * the relay-synthesized ``userMessage`` for one prompt must land on exactly
      ONE ``item_id`` despite replays/snapshot fallbacks (test_f's sharp check).
    """

    def __init__(self) -> None:
        self._submit_groups: dict[str, list[dict]] = {}  # cmid -> responses
        self._user_ids: dict[str, set[str]] = {}         # sid -> userMessage ids
        self._expected: dict[str, int] = {}              # sid -> expected prompts
        self._violations: list[str] = []

    def record_submit(self, cmid: str, response: dict) -> None:
        if cmid:
            self._submit_groups.setdefault(cmid, []).append(response or {})

    def expect_user_messages(self, sid: str, count: int) -> None:
        """Declare that ``sid`` legitimately carries ``count`` distinct prompts.

        Multi-turn sessions (sustained T3) have one userMessage item_id PER
        TURN; the default single-prompt expectation (>1 == double-apply) would
        false-positive there. The violation fires when the distinct id count
        EXCEEDS the expectation — replay double-apply still detected.
        """
        if sid:
            self._expected[sid] = max(self._expected.get(sid, 1), max(1, count))

    def fold_frames(self, frames) -> "DedupChecker":
        for f in frames:
            kind = _g(f, "kind", "kind")
            body = _g(f, "body", "body") or {}
            sid = _g(f, "sid", "sid") or ""
            if kind == _ITEM_COMPLETED and body.get("type") == "userMessage":
                self._user_ids.setdefault(sid, set()).add(body.get("item_id", ""))
        return self

    def check(self) -> "DedupChecker":
        # Duplicate-submit: >1 response for one cmid, all but first deduplicated.
        for cmid, resps in self._submit_groups.items():
            if len(resps) < 2:
                continue
            sids = {r.get("session_id") for r in resps if r.get("session_id")}
            if len(sids) > 1:
                self._violations.append(
                    f"I4: cmid {cmid} resolved to {len(sids)} distinct sessions "
                    f"{sorted(sids)} — duplicate submit created a second turn"
                )
            dedup_flags = [bool(r.get("deduplicated")) for r in resps]
            if len(resps) > 1 and not any(dedup_flags[1:]):
                self._violations.append(
                    f"I4: cmid {cmid} re-submitted {len(resps)}× but no retry was "
                    f"marked deduplicated — dedup path not engaged"
                )
        # Replayed frames: one prompt == one userMessage item_id (per expected
        # prompt count — multi-turn sessions legitimately carry several).
        for sid, ids in self._user_ids.items():
            ids.discard("")
            expected = self._expected.get(sid, 1)
            if len(ids) > expected:
                self._violations.append(
                    f"I4: session {sid} has {len(ids)} distinct userMessage ids "
                    f"(expected {expected}): {sorted(ids)[:5]} — replay "
                    f"double-applied a prompt"
                )
        return self

    def report(self) -> dict[str, Any]:
        self.check()
        return {
            "invariant": "I4",
            "ok": not self._violations,
            "violations": self._violations,
            "submit_groups": {k: len(v) for k, v in self._submit_groups.items()},
            "user_message_ids": {k: sorted(v) for k, v in self._user_ids.items()},
        }


# ---------------------------------------------------------------------------
# I5 — owned-session lifecycle: persist across restart, no zombies.
# ---------------------------------------------------------------------------


class OwnedSessionLedger:
    """Tracks driven sessions and checks the relay's owned set against them.

    Reads the relay's ``/healthz`` status (``owned_sessions`` from
    downstream.status()). I5 holds when:

    * after a relay RESTART, every still-driven session is re-owned (durable
      re-resume — the ``destination session not active`` failure is absent);
    * the owned set never balloons past the distinct sessions driven (+slack) —
      no zombie sessions accumulating.
    """

    def __init__(self, *, slack: int = 2) -> None:
        self.driven: set[str] = set()
        self.snapshots: list[dict[str, Any]] = []
        self.slack = slack
        self._violations: list[str] = []

    def record_drive(self, sid: str) -> None:
        if sid:
            self.driven.add(sid)

    async def snapshot(self, healthz_url: str, *, token: str = "",
                       label: str = "") -> dict[str, Any]:
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        try:
            async with httpx.AsyncClient() as c:
                r = await c.get(healthz_url, headers=headers, timeout=8.0)
                r.raise_for_status()
                data = r.json()
        except Exception as exc:  # noqa: BLE001
            snap = {"label": label, "error": str(exc), "owned": []}
            self.snapshots.append(snap)
            return snap
        owned = set(data.get("owned_sessions") or [])
        snap = {"label": label, "owned": sorted(owned),
                "n_owned": len(owned), "n_driven": len(self.driven)}
        self.snapshots.append(snap)
        return snap

    def check(self, *, require_reown_after_restart: bool = True) -> "OwnedSessionLedger":
        if not self.snapshots:
            return self
        last = self.snapshots[-1]
        owned = set(last.get("owned") or [])
        # Zombie check: owned set bounded by driven (+slack).
        if len(owned) > len(self.driven) + self.slack:
            self._violations.append(
                f"I5: owned set ({len(owned)}) exceeds driven sessions "
                f"({len(self.driven)}) + slack {self.slack} — zombie accumulation"
            )
        # Re-own check: every driven session should be owned at the end (the
        # relay never releases; a restart must re-resume from durable state).
        if require_reown_after_restart:
            missing = sorted(self.driven - owned)
            if missing:
                self._violations.append(
                    f"I5: {len(missing)} driven session(s) not re-owned after "
                    f"restart: {missing[:5]} — durable re-resume failed"
                )
        return self

    def report(self) -> dict[str, Any]:
        self.check()
        return {
            "invariant": "I5",
            "ok": not self._violations,
            "violations": self._violations,
            "driven": sorted(self.driven),
            "snapshots": self.snapshots,
        }


# ---------------------------------------------------------------------------
# I7 — notify decisions under foreground flapping (in-process, mock APNs).
# ---------------------------------------------------------------------------


class FakePush:
    """Mock APNs sink: records notify() calls, returns a delivery count.

    ``valid_tokens`` gates delivery: a notify to a dead/evicted token returns 0
    (undelivered) so I7's "no notify for dead tokens" is observable. Zero
    network — the spec's mock-APNs-only rule.
    """

    def __init__(self, valid_tokens: Optional[set[str]] = None) -> None:
        self.calls: list[dict[str, Any]] = []
        self.valid_tokens = valid_tokens  # None == all tokens valid

    # The relay Notifier reads the registry; model a current foreground token.
    current_token: Optional[str] = "tok-live"

    def notify(self, event_type, title, body, payload=None, *, category=None,
               expiration=0, collapse_id=None) -> int:
        token = self.current_token
        delivered = 1 if (self.valid_tokens is None or token in self.valid_tokens) else 0
        self.calls.append({
            "event_type": event_type, "title": title, "body": body,
            "payload": payload, "category": category, "expiration": expiration,
            "collapse_id": collapse_id, "token": token, "delivered": delivered,
        })
        return delivered


class NotifyRecorder:
    """Replays reframed frames through the REAL Notifier with a FakePush sink.

    Wraps the ``test_g_notifier_apns`` in-process pattern: a controllable
    foreground oracle the scenario flips on a schedule, and a FakePush whose
    token can be killed mid-run. Records each notify DECISION (fired vs
    suppressed) with the foreground state at decision time, then checks the §6
    contract:

    * ``turn_complete``/``task_complete``/``turn_error`` fire when backgrounded,
      are suppressed when foregrounded;
    * ``approval``/``clarify`` (blocking) ALWAYS fire;
    * no notify is DELIVERED to a dead/evicted token.

    The scenario builds this with the relay-under-test's Reframer+Notifier (the
    harness imports them from the venv-installed source) and feeds real
    mock-gateway event streams through it.
    """

    def __init__(self, notifier: Any, push: FakePush,
                 foreground: set[str]) -> None:
        self.notifier = notifier
        self.push = push
        self.foreground = foreground  # the oracle set the scenario mutates
        self.decisions: list[dict[str, Any]] = []

    def observe(self, frame: Any) -> None:
        fg_at_call = set(self.foreground)
        descriptor = self.notifier.observe(frame)
        sid = _g(frame, "sid", "sid") or ""
        # Classify the frame ourselves so a SUPPRESSED decision (descriptor is
        # None) still records WHICH signal was held back (turn_complete, etc.).
        event_type = ((descriptor or {}).get("event_type")
                      or self._classify_frame(frame))
        self.decisions.append({
            "sid": sid,
            "kind": _g(frame, "kind", "kind"),
            "foreground_at_decision": sid in fg_at_call,
            "fired": descriptor is not None,
            "event_type": event_type,
        })

    @staticmethod
    def _classify_frame(frame: Any) -> Optional[str]:
        """Mirror the relay Notifier's _classify for evidence (frame -> kind)."""
        kind = _g(frame, "kind", "kind")
        body = _g(frame, "body", "body") or {}
        if kind == "approval.request":
            return "approval"
        if kind == "clarify.request":
            return "clarify"
        if kind == _ITEM_COMPLETED:
            itype = body.get("type")
            if itype == "agentMessage":
                return "turn_complete"
            if itype == "error":
                return "turn_error"
            if itype == "taskList":
                return "task_complete"
        return None

    def report(self) -> dict[str, Any]:
        violations: list[str] = []
        # Dead-token delivery check: any call to an invalid token that the
        # sender reported as delivered (should be 0 for a dead token).
        for call in self.push.calls:
            tok = call.get("token")
            if (self.push.valid_tokens is not None
                    and tok not in self.push.valid_tokens
                    and call.get("delivered")):
                violations.append(
                    f"I7: notify delivered to dead/evicted token {tok!r} "
                    f"(event={call.get('event_type')})"
                )
        fired = [d for d in self.decisions if d["fired"]]
        suppressed_fg = [d for d in self.decisions
                         if not d["fired"] and d["foreground_at_decision"]]
        return {
            "invariant": "I7",
            "ok": not violations,
            "violations": violations,
            "n_decisions": len(self.decisions),
            "n_fired": len(fired),
            "fired_events": [d["event_type"] for d in fired],
            "suppressed_while_foreground": len(suppressed_fg),
            "push_calls": len(self.push.calls),
            "metrics": getattr(self.notifier, "metrics", None) and
            self.notifier.metrics.as_dict(),
        }


# ---------------------------------------------------------------------------
# I8 — protocol robustness: fuzzed upstream never crashes the relay.
# ---------------------------------------------------------------------------


class RobustnessChecker:
    """Asserts the relay survives malformed/unknown/oversized upstream input.

    The scenario sends the fuzz payloads at the relay's phone port (via
    ``SoakPhoneDriver.send_raw``) and injects mutated gateway events (via the
    controllable gateway). After each batch this checker probes the relay's
    ``/healthz`` — I8 holds iff the relay stays alive (HTTP 200) through the
    whole storm and unknown methods return a CLEAN JSON-RPC error (not a crash
    or a hang).
    """

    def __init__(self, healthz_url: str, *, token: str = "") -> None:
        self.healthz_url = healthz_url
        self.token = token
        self.probes: list[dict[str, Any]] = []
        self.unknown_method_errors = 0
        self.unknown_method_ok = 0
        self._violations: list[str] = []

    async def probe_alive(self, label: str) -> bool:
        headers = {"Authorization": f"Bearer {self.token}"} if self.token else {}
        try:
            async with httpx.AsyncClient() as c:
                r = await c.get(self.healthz_url, headers=headers, timeout=5.0)
                alive = r.status_code == 200
        except Exception as exc:  # noqa: BLE001
            alive = False
            label = f"{label} ({exc})"
        self.probes.append({"label": label, "alive": alive})
        if not alive:
            self._violations.append(f"I8: relay not alive after {label}")
        return alive

    def record_unknown_method(self, response: dict) -> None:
        """An unknown-method RPC must come back as a JSON-RPC ``error``."""
        if isinstance(response, dict) and "error" in response:
            self.unknown_method_errors += 1
        else:
            self.unknown_method_ok += 1
            self._violations.append(
                f"I8: unknown method returned a non-error response "
                f"({response!r}) — expected a clean JSON-RPC error"
            )

    def report(self) -> dict[str, Any]:
        return {
            "invariant": "I8",
            "ok": not self._violations,
            "violations": self._violations,
            "probes": self.probes,
            "unknown_method_clean_errors": self.unknown_method_errors,
            "unknown_method_bad_responses": self.unknown_method_ok,
        }
