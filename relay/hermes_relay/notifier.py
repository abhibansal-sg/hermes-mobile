"""Lane 4 — Notifier: owned-session APNs pushes via existing plumbing.

Observes the relay's frame stream (``TOPIC_RELAY_FRAMES``) and, for sessions the
:class:`~hermes_relay.gateway_client.GatewayClient` OWNS, fires an APNs push on
the push-worthy signals (protocol §6):

* ``item.completed`` of an ``agentMessage`` -> ``turn_complete`` push
* ``approval.request``                      -> ``approval`` push (blocking)
* ``clarify.request``                       -> ``clarify`` push (blocking)
* ``item.completed`` of an ``error``        -> ``turn_error`` push
* ``item.completed`` of a ``taskList``      -> ``task_complete`` push
  (the reframer only completes a taskList once every task is done)

It fires by REUSING the existing ``plugins/hermes-mobile/push_engine.notify()``
plumbing (device-token registry + direct HTTP/2 APNs or relay-mode delivery) —
NO gateway code, NO new push path. The gate (protocol §6): SKIP the push when a
live phone WS currently holds that session foregrounded, i.e.
``DownstreamServer.session_has_live_phone(sid)`` is True — the user is already
watching, so a notification would be noise.

Two deviations from a naive "gate everything" reading, each matching the
existing gateway push worker (``push_engine._run_push_work``) that this lane
mirrors:

* **approval + clarify always notify.** Both are *blocking* interactions — the
  turn is stalled until the user answers — so they bypass the foreground
  suppression (the gateway path never foreground-gates these gates).
* **turn_complete / task_complete / error are foreground-gated.** A completion
  or error the user is already watching live is noise (STR-987 attention gate).

Scope: OWNED sessions only. Foreign-session notifications are PARKED (they need
the broadcast/co-watch track; the relay as a pure client never receives a
foreign session's live stream).

Dedupe: the reframed stream can re-emit a logical signal (e.g. two
``agentMessage`` items in one turn, or a replayed frame). Each push-worthy
signal is reduced to a stable identity ``(sid, event_type, key)`` and fired at
most once from a bounded LRU — the phone never gets a double banner for one
turn/approval/error.

INTERFACE THE LANE IMPLEMENTS: :meth:`run` (the observer pump) + :meth:`observe`
(the per-frame decision, unit-testable without a socket). Push delivery is
delegated to the injected ``push_engine`` module (via plugin_bridge), so tests
inject a fake.
"""

from __future__ import annotations

import asyncio
import logging
import re
from collections import OrderedDict
from dataclasses import dataclass
from typing import Any, Callable, Optional

from . import plugin_bridge
from .bus import EventBus, TOPIC_RELAY_FRAMES
from .gateway_client import GatewayClient
from .durable_state import DurableState
from .types import Frame, FrameKind, ItemType

_log = logging.getLogger(__name__)

# APNs 4h store-and-forward window for turn-complete banners (mirrors the
# gateway push worker: a locked/off phone should still get the banner on wake).
# Time-sensitive alerts (approval/error) keep expiration=0.
_TURN_COMPLETE_EXPIRATION_S = 14400


@dataclass
class NotifierConfig:
    """Notifier tuning. ``enabled`` lets the lane be dark in dev/tests."""

    enabled: bool = True
    # Map relay signal -> push_engine event_type. Defaults are the exact
    # PUSH_EVENT_KINDS the reused push_engine + iOS action categories expect
    # (``task_complete`` is a relay-local kind push_engine passes through).
    turn_complete_event: str = "turn_complete"
    approval_event: str = "approval"
    clarify_event: str = "clarify"
    error_event: str = "turn_error"
    task_complete_event: str = "task_complete"
    # iOS UNNotificationCategory action sets (match the gateway push worker).
    turn_complete_category: str = "HERMES_TURN"
    approval_category: str = "HERMES_APPROVAL"
    clarify_category: str = "HERMES_CLARIFY"
    error_category: str = "HERMES_ERROR"
    task_complete_category: str = "HERMES_TURN"
    # Bounded dedupe LRU size (per relay process, across all sessions).
    dedupe_capacity: int = 512

    def blocking_events(self) -> frozenset[str]:
        """Push kinds that BYPASS the §6 foreground gate (the turn is stalled
        on the user): approval and clarify are both blocking interactions."""
        return frozenset({self.approval_event, self.clarify_event})


@dataclass
class NotifierMetrics:
    """Observability counters — asserted in tests, dumped as evidence."""

    fired: int = 0
    skipped_not_pushworthy: int = 0
    skipped_unowned: int = 0
    suppressed_foreground: int = 0
    suppressed_dedupe: int = 0

    def as_dict(self) -> dict[str, int]:
        return {
            "fired": self.fired,
            "skipped_not_pushworthy": self.skipped_not_pushworthy,
            "skipped_unowned": self.skipped_unowned,
            "suppressed_foreground": self.suppressed_foreground,
            "suppressed_dedupe": self.suppressed_dedupe,
        }


class Notifier:
    """Fires owned-session APNs pushes, gated on live-phone foreground."""

    def __init__(
        self,
        config: NotifierConfig,
        bus: EventBus,
        gateway: GatewayClient,
        *,
        is_foregrounded: Callable[[str], bool],
        push_engine: Any = None,
        durable: Optional[DurableState] = None,
    ) -> None:
        self._cfg = config
        self._bus = bus
        self._gateway = gateway
        # Injected DownstreamServer.session_has_live_phone (the §6 gate).
        self._is_foregrounded = is_foregrounded
        # Injected push_engine module (plugin_bridge.import_push_engine()); a
        # fake is injected in tests. Resolved lazily in run() if None.
        self._push = push_engine
        self._durable = durable
        # Bounded LRU of already-fired signal identities (dedupe). Value unused;
        # OrderedDict gives O(1) move-to-end + evict-oldest.
        self._seen: "OrderedDict[tuple[str, str, str], None]" = OrderedDict()
        self.metrics = NotifierMetrics()

    async def run(self) -> None:
        """Pump: subscribe ``TOPIC_RELAY_FRAMES`` and call :meth:`observe`.

        Lazily resolves the reused ``push_engine`` module (via plugin_bridge)
        when not injected. Runs until cancelled / the subscription closes. A
        per-frame failure is logged and swallowed — one bad frame must never
        tear down the push observer.
        """
        if self._push is None:
            self._push = plugin_bridge.import_push_engine()
        sub = self._bus.subscribe(TOPIC_RELAY_FRAMES)
        drain_task = asyncio.create_task(self._drain_loop()) if self._durable else None
        try:
            async for frame in sub:
                try:
                    self.observe(frame)
                except Exception:  # pragma: no cover - defensive
                    _log.debug("notifier.observe failed", exc_info=True)
        finally:
            if drain_task is not None:
                drain_task.cancel()
                await asyncio.gather(drain_task, return_exceptions=True)
            self._bus.unsubscribe(sub)

    async def _drain_loop(self) -> None:
        while True:
            self._drain_outbox()
            await asyncio.sleep(1)

    def observe(self, frame: Frame) -> Optional[dict[str, Any]]:
        """Decide whether ``frame`` warrants a push; fire it if so.

        Returns the push descriptor that was sent (event_type/title/body/sid/
        category) or ``None`` when no push was warranted (not owned, gated by
        foreground, deduped, or not a push-worthy signal). Pure-decision +
        delegated send, so a unit test asserts on the return value with a fake
        push_engine.
        """
        if not self._cfg.enabled:
            return None

        event_type = self._should_push(frame)
        if event_type is None:
            return None

        identity = self._identity(event_type, frame)
        if identity in self._seen:
            self._seen.move_to_end(identity)
            self.metrics.suppressed_dedupe += 1
            return None
        self._remember(identity)

        descriptor = self._fire(event_type, frame)
        self.metrics.fired += 1
        return descriptor

    def _should_push(self, frame: Frame) -> Optional[str]:
        """Return the push event_type for a push-worthy frame, else ``None``.

        Push-worthy: agentMessage ``item.completed`` (-> turn_complete),
        ``approval.request`` (-> approval), or an error ``item.completed``
        (-> turn_error). Returns ``None`` unless the frame's session is OWNED;
        turn_complete/error additionally require the session to NOT be
        foregrounded on a live phone (protocol §6 gate). Approval is a blocking
        gate and bypasses foreground suppression.
        """
        event_type = self._classify(frame)
        if event_type is None:
            self.metrics.skipped_not_pushworthy += 1
            return None

        sid = frame.sid
        if not sid or not self._gateway.owns(sid):
            self.metrics.skipped_unowned += 1
            return None

        # Blocking gates (approval/clarify) always notify — the turn is stalled
        # on the user; every other signal respects the §6 foreground gate.
        if event_type not in self._cfg.blocking_events() and self._is_foregrounded(sid):
            self.metrics.suppressed_foreground += 1
            return None

        return event_type

    def _classify(self, frame: Frame) -> Optional[str]:
        """Map a frame to its push event_type, or ``None`` if not push-worthy."""
        kind = frame.kind
        if kind == FrameKind.APPROVAL_REQUEST:
            return self._cfg.approval_event
        if kind == FrameKind.CLARIFY_REQUEST:
            return self._cfg.clarify_event
        if kind == FrameKind.ITEM_COMPLETED:
            item_type = (frame.body or {}).get("type")
            if item_type == ItemType.AGENT_MESSAGE:
                return self._cfg.turn_complete_event
            if item_type == ItemType.ERROR:
                return self._cfg.error_event
            # A taskList reaches item.completed ONLY when every task is done
            # (the reframer emits deltas while work remains) — the task-list-
            # complete push signal.
            if item_type == ItemType.TASK_LIST:
                return self._cfg.task_complete_event
        return None

    def _identity(self, event_type: str, frame: Frame) -> tuple[str, str, str]:
        """Stable dedupe key for a push-worthy signal.

        turn_complete/error collapse to one push per turn (so multiple items in
        a turn don't double-ring); approval keys on the request id so distinct
        approvals in one turn each ring. Falls back to the item id, then the
        turn id, then an empty key.
        """
        body = frame.body or {}
        if event_type in (self._cfg.approval_event, self._cfg.clarify_event):
            # Approval/clarify frames are flat (not item.to_dict()); each distinct
            # request id rings once (two gates in one turn each notify).
            key = str(
                body.get("approval_id")
                or body.get("request_id")
                or body.get("id")
                or frame.turn
                or ""
            )
        else:
            # One banner per turn; fall back to the item id when turn is absent.
            key = str(frame.turn or body.get("item_id") or "")
        return (frame.sid, event_type, key)

    def _remember(self, identity: tuple[str, str, str]) -> None:
        """Record a fired identity in the bounded LRU (evict oldest on cap)."""
        self._seen[identity] = None
        self._seen.move_to_end(identity)
        while len(self._seen) > self._cfg.dedupe_capacity:
            self._seen.popitem(last=False)

    def _fire(self, event_type: str, frame: Frame) -> dict[str, Any]:
        """Build the alert text and call ``push_engine.notify(...)``.

        Reuses the existing signature
        ``notify(event_type, title, body, payload, *, category, expiration,
        collapse_id)`` — no new APNs code, which is the whole point of the
        reuse. Returns the push descriptor (also the unit-test assertion shape).
        """
        sid = frame.sid
        title, body_text, category, expiration = self._render(event_type, frame)

        payload: dict[str, Any] = {"session_id": sid}
        if frame.turn:
            payload["turn_id"] = frame.turn
        item_id = (frame.body or {}).get("item_id")
        if item_id:
            payload["item_id"] = item_id
        # Stable collapse id so a re-fire (or APNs-side coalescing) folds onto
        # the same banner rather than stacking.
        collapse_id = f"{sid}:{event_type}:{self._identity(event_type, frame)[2]}"

        descriptor = {
            "event_type": event_type, "sid": sid, "title": title,
            "body": body_text, "category": category, "expiration": expiration,
            "collapse_id": collapse_id, "payload": payload,
        }
        if self._durable is not None:
            self._durable.enqueue_push(descriptor)
            self._drain_outbox()
        else:
            self._send(descriptor)

        return descriptor

    def _send(self, descriptor: dict[str, Any]) -> int:
        if self._push is not None:
            try:
                return int(self._push.notify(
                    descriptor["event_type"], descriptor["title"], descriptor["body"],
                    descriptor["payload"], category=descriptor["category"],
                    expiration=descriptor["expiration"], collapse_id=descriptor["collapse_id"],
                ))
            except Exception:  # pragma: no cover - notify() never raises, belt+braces
                _log.debug("push_engine.notify failed", exc_info=True)
        return 0

    def _drain_outbox(self) -> None:
        if self._durable is None:
            return
        for descriptor in self._durable.due_pushes():
            delivered = self._send(descriptor) > 0
            self._durable.finish_push(
                descriptor["_event_id"], delivered, descriptor["_attempts"]
            )

    def _render(self, event_type: str, frame: Frame) -> tuple[str, str, str, int]:
        """Return ``(title, body, category, expiration)`` for a push.

        Text/category mirror the gateway push worker so the phone renders an
        identical banner whether the push originated at the gateway or here.
        Item frames (turn_complete/error) carry their content nested under the
        item dict's ``body`` key (``Item.to_dict``); approval frames are flat.
        """
        frame_body = frame.body or {}
        cfg = self._cfg
        if event_type == cfg.approval_event:
            title = _safe_text(frame_body.get("title"), "Approval required", max_chars=80)
            text = _safe_text(
                frame_body.get("description") or frame_body.get("target"),
                "Review this approval in Hermes",
            )
            return title, text, cfg.approval_category, 0

        if event_type == cfg.clarify_event:
            # A blocking clarify gate — flat body, question verbatim (mirrors the
            # gateway push worker's "Hermes has a question" banner).
            text = _safe_text(
                frame_body.get("question") or frame_body.get("prompt"),
                "Hermes needs your input to continue",
            )
            return "Hermes has a question", text, cfg.clarify_category, 0

        content = _item_content(frame_body)
        summary = frame_body.get("summary")
        if event_type == cfg.error_event:
            text = _safe_text(
                content.get("message") or content.get("text") or summary, "Turn errored"
            )
            return "Hermes hit an error", _humanize_raw_error(text) or text, cfg.error_category, 0
        if event_type == cfg.task_complete_event:
            # taskList item.completed: the card summary ("Tasks N/N") is the
            # human line; store-and-forward like turn_complete.
            text = _safe_text(summary or content.get("text"), "All tasks complete")
            return (
                "Hermes finished its tasks",
                _humanize_raw_error(text) or text,
                cfg.task_complete_category,
                _TURN_COMPLETE_EXPIRATION_S,
            )
        # turn_complete — QA-3 S5/C3: a turn can COMPLETE carrying an upstream
        # provider error as its final message text (the gateway surfaces the
        # llm-proxy OAuth failure verbatim: `HTTP 403: {"code": ...}`). The
        # reframer emits a normal `agentMessage` completion for it (NOT an
        # `error` item), so this branch — not error_event — forwarded the raw
        # JSON to APNs and the lock screen showed error theater (IMG_2583).
        # Classify the terminal text: a raw-error shape becomes ONE honest
        # human line under the error treatment, never verbatim.
        raw = content.get("text") or summary
        humanized = _humanize_raw_error(_safe_text(raw, ""))
        if humanized:
            return (
                "Hermes hit an error",
                humanized,
                cfg.error_category,
                _TURN_COMPLETE_EXPIRATION_S,
            )
        text = _safe_text(raw, "Turn finished")
        return "Hermes finished", text, cfg.turn_complete_category, _TURN_COMPLETE_EXPIRATION_S


def _item_content(frame_body: dict[str, Any]) -> dict[str, Any]:
    """The item's type-specific content dict (``Item.to_dict()['body']``).

    Item frames wrap the rendered content one level down under ``body``; return
    it as a dict (or empty when a caller handed us a flat/malformed body).
    """
    content = frame_body.get("body")
    return content if isinstance(content, dict) else {}


def _safe_text(value: Any, default: str, *, max_chars: int = 240) -> str:
    """First non-empty line of ``value``, trimmed and capped, else ``default``.

    A tiny local sanitizer (the push_engine equivalent is private) so an alert
    body is always a single, bounded, non-empty line.
    """
    if not isinstance(value, str):
        return default
    stripped = value.strip()
    if not stripped:
        return default
    first_line = stripped.splitlines()[0].strip()
    if not first_line:
        return default
    if len(first_line) > max_chars:
        first_line = first_line[: max_chars - 1].rstrip() + "…"
    return first_line


# QA-3 S5/C3 — raw-error classifier. A turn that completes carrying an upstream
# provider failure as its text (owner forensics IMG_2583: `HTTP 403: {"code":
# "unauthenticated:bad-credentials","error":"The OAuth2 access token could not
# be validated."}`) must NEVER reach the lock screen verbatim — that is error
# theater. Two raw shapes are detected:
#
# 1. a provider HTTP error line — `HTTP 4xx:` / `HTTP 5xx:` prefix (a SUCCESS
#    code like `HTTP 200:` in agent prose is NOT an error and never matches);
# 2. a bare JSON error payload — a `{...}` first line carrying a `"code"` or
#    `"error"` key.
#
# Returns ONE honest human line (auth-shaped failures get an auth line), or
# `None` when the text is ordinary prose. The iOS twin (`RawErrorSanitizer` in
# HermesMobile/Support) implements the identical rules so in-transcript renders
# and push bodies agree word-for-word.
_HTTP_ERROR_PREFIX = re.compile(r"^\s*HTTP\s+[45]\d\d\s*:", re.IGNORECASE)
_AUTH_HINTS = (
    "unauthenticated", "bad-credentials", "bad_credentials", "oauth",
    "access token", "api key", "api_key", "401", "403",
)


def _humanize_raw_error(text: str) -> Optional[str]:
    """Map a raw-error terminal text to a human line, or ``None`` if not raw."""
    if not isinstance(text, str):
        return None
    stripped = text.strip()
    if not stripped:
        return None
    first_line = stripped.splitlines()[0].strip()
    is_raw = bool(_HTTP_ERROR_PREFIX.match(first_line))
    if not is_raw and first_line.startswith("{") and first_line.endswith("}"):
        is_raw = '"code"' in first_line or '"error"' in first_line
    if not is_raw:
        return None
    lowered = stripped.lower()
    if any(hint in lowered for hint in _AUTH_HINTS):
        return "Auth for this session's provider has expired — re-authentication is needed."
    return "The provider returned an error — open the session for details."
