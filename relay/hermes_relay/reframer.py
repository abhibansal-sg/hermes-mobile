"""Lane 2 — Reframer: raw gateway events -> ratified item envelope.

The single mapping layer (protocol §2/§3). It consumes
:class:`~hermes_relay.types.GatewayEvent` off ``TOPIC_GATEWAY_EVENTS`` and emits
zero or more :class:`~hermes_relay.types.Frame` objects (seq unstamped) onto
``TOPIC_RELAY_FRAMES``. It holds per-session bookkeeping — the
:class:`~hermes_relay.session_state.SessionStore` for accumulated items (ord +
snapshot) plus a small transient :class:`_Ctx` per session for turn/open-item
tracking — to assign stable ``item_id`` and monotonic ``ord`` and to know which
in-progress item a delta belongs to.

The raw -> item mapping (grounded in the R0 fixture AND the gateway's own
``tui_gateway/server.py`` ``_emit(...)`` sites, protocol §2 catalog):

| raw event (``type``)               | -> frame(s)                                       |
|------------------------------------|---------------------------------------------------|
| ``message.start`` (payload null)   | ``turn.started`` (opens a turn; no item yet)      |
| ``message.delta`` (``.text``)      | lazy ``item.started`` agentMessage + ``item.delta``|
| ``message.complete`` (``.text,     | ``item.completed`` agentMessage (authoritative) + |
|   .usage``)                        |   ``usage`` item + ``turn.completed`` (usage)     |
| ``reasoning.delta`` (``.text``)    | lazy ``item.started`` reasoning + ``item.delta``  |
| ``reasoning.available`` (``.text``)| ``item.completed`` reasoning (authoritative)      |
| ``thinking.delta`` (``.text``)     | ``status`` frame ``{kind:"thinking"}`` (ephemeral)|
| ``tool.start`` (``.tool_id,.name``)| ``item.started`` toolCall/browser/image (id=tool_id)|
| ``tool.complete`` (``.tool_id,     | ``item.completed`` toolCall — OR ``fileChange``   |
|   .name,.args,.result,             |   when ``inline_diff`` present; ``browser`` for   |
|   .duration_s,.inline_diff``)      |   ``browser_*``; ``image`` for image tools        |
| ``tool.*`` with ``name=="todo"``   | dedicated ``taskList`` item on a STABLE id —      |
|   (``.todos`` full list on complete)|  started (snapshot) / delta (update) / completed  |
|                                     |  (all tasks done); NOT a generic toolCall         |
| ``error`` (``.message``)           | ``item.completed`` error (status=failed)          |
| ``status.update`` (``.kind,.text``)| ``status`` frame (non-item chatter)               |
| ``session.title``/``title``        | ``title`` frame                                   |
| ``approval.request``               | ``approval.request`` frame (interactive gate)     |
| ``clarify.request``                | ``clarify.request`` frame (interactive gate)      |
| ``session.info``/``gateway.ready`` | ignored (session/gateway metadata, not turn content)|
| anything else (unknown)            | generic ``toolCall`` item — NEVER dropped         |

Type-selection rule (protocol §2 forward-compat): EVERY tool maps to a generic
``toolCall`` keyed by ``name``; the special types (``fileChange``/``image``/
``browser``) are refinements chosen from the tool ``name`` / result shape. An
unrecognized tool — and even an unrecognized top-level event — still yields a
valid ordered item, so the phone never breaks on a new Hermes tool/event.

``message.complete`` and ``tool.complete`` payloads are the AUTHORITATIVE
completed items: their ``item.completed`` frame carries the full body and
replaces whatever the deltas accumulated (the ``completed``-is-authoritative
rule, protocol §2/§4).

INTERFACE THE LANE IMPLEMENTS: :meth:`reframe` (per-event mapping that also folds
its own output into the :class:`SessionStore` so a resume-as-items snapshot is
always current) plus the :meth:`run` pump. Pure function of the event stream —
no gateway dependency, no I/O.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Optional

from .bus import TOPIC_GATEWAY_EVENTS, TOPIC_RELAY_FRAMES, EventBus
from .session_state import SessionStore
from .types import (
    Frame,
    FrameKind,
    GatewayEvent,
    Item,
    ItemStatus,
    ItemType,
    RawEvent,
)

# Tool name families that get a special render (protocol §2). Everything else is
# a generic toolCall. Kept as data so the mapping stays declarative.
_BROWSER_PREFIX = "browser_"
_IMAGE_TOOLS = frozenset({"image_generate", "image_edit"})

# The agent's task/todo list rides on the generic ``todo`` tool (tool.start /
# tool.complete, name == "todo"): the gateway lifts the authoritative full list
# to a top-level ``todos`` key on tool.complete. Instead of letting it fall
# through to a generic toolCall, the reframer gives it a DEDICATED ``taskList``
# item on a STABLE per-session id (protocol §2), so the phone renders one living
# task card that is snapshotted on first sight and updated in place thereafter.
_TASK_TOOL = "todo"
# Terminal task statuses — a list whose every task is one of these is "done"
# (drives the ``taskList`` item.completed frame + the task-list-complete push).
_TASK_DONE_STATUSES = frozenset({"completed", "cancelled"})
# Canonical task status order for the counts summary.
_TASK_STATUSES = ("pending", "in_progress", "completed", "cancelled")

# Top-level events that are gateway/session metadata, not turn content. They
# produce no downstream frame (they are neither ordered items nor phone chatter).
_IGNORED_EVENTS = frozenset({RawEvent.GATEWAY_READY, RawEvent.SESSION_INFO})


@dataclass
class _Ctx:
    """Transient per-session reframer bookkeeping (mapping state only).

    Distinct from :class:`SessionState`, which holds the accumulated *items*.
    This tracks the turn currently open and which synthesized item id the next
    text/reasoning delta belongs to, plus monotonic counters for id synthesis.
    """

    turn_seq: int = 0
    item_seq: int = 0
    current_turn: Optional[str] = None
    text_item: Optional[str] = None
    reasoning_item: Optional[str] = None
    # For id-LESS tools only: name -> the synthesized item_id assigned at
    # tool.start, so the matching tool.complete lands on the SAME card. Tools
    # that carry a real ``tool_id`` never touch this map (they correlate on it).
    open_tools_by_name: dict[str, str] = field(default_factory=dict)


class Reframer:
    """Maps one gateway stream into the item-lifecycle envelope."""

    def __init__(self, bus: EventBus, store: SessionStore) -> None:
        self._bus = bus
        self._store = store
        self._ctx: dict[str, _Ctx] = {}

    # -- pump ------------------------------------------------------------
    async def run(self) -> None:
        """Pump: subscribe ``TOPIC_GATEWAY_EVENTS``, reframe, publish frames.

        For each inbound event, call :meth:`reframe` (which also folds its output
        into the SessionStore), then publish every emitted frame to
        ``TOPIC_RELAY_FRAMES``. A single malformed event never kills the pump.
        Runs until cancelled/closed.
        """
        sub = self._bus.subscribe(TOPIC_GATEWAY_EVENTS)
        try:
            async for event in sub:
                if not isinstance(event, GatewayEvent):
                    continue
                try:
                    frames = self.reframe(event)
                except Exception:  # pragma: no cover - defensive pump guard
                    continue
                for frame in frames:
                    self._bus.publish(TOPIC_RELAY_FRAMES, frame)
        finally:
            self._bus.unsubscribe(sub)

    # -- mapping ---------------------------------------------------------
    def reframe(self, event: GatewayEvent) -> list[Frame]:
        """Map ONE raw gateway event to zero+ downstream frames (seq unstamped).

        Reads/writes per-session bookkeeping (the :class:`_Ctx` mapping state and
        the :class:`SessionStore` item accumulator: ord allocation, in-progress
        item tracking) and folds every frame it emits into the store so the
        snapshot/resync path stays current. This is the function every mapping
        unit test drives.
        """
        sid = event.session_id
        if not sid:
            # gateway.ready and other session-less signals carry no per-session
            # item; nothing to reframe.
            return []

        etype = event.type
        if etype in _IGNORED_EVENTS:
            return []

        if etype in (RawEvent.MESSAGE_START, RawEvent.MESSAGE_DELTA, RawEvent.MESSAGE_COMPLETE):
            frames = self._reframe_message(event)
        elif etype in (RawEvent.REASONING_DELTA, RawEvent.REASONING_AVAILABLE):
            frames = self._reframe_reasoning(event)
        elif etype == RawEvent.THINKING_DELTA:
            frames = self._reframe_thinking(event)
        elif etype in (RawEvent.TOOL_START, RawEvent.TOOL_COMPLETE):
            frames = self._reframe_tool(event)
        elif etype == RawEvent.ERROR:
            frames = self._reframe_error(event)
        elif etype == RawEvent.STATUS_UPDATE:
            frames = self._reframe_status(event)
        elif etype in (RawEvent.SESSION_TITLE, RawEvent.TITLE):
            frames = self._reframe_title(event)
        elif etype == RawEvent.APPROVAL_REQUEST:
            frames = self._reframe_interactive(event, FrameKind.APPROVAL_REQUEST)
        elif etype == RawEvent.CLARIFY_REQUEST:
            frames = self._reframe_interactive(event, FrameKind.CLARIFY_REQUEST)
        else:
            # Forward-compat: an unrecognized event is never dropped — it becomes
            # a generic toolCall item so the phone renders *something* stable.
            frames = self._reframe_unknown(event)

        # Fold every emitted frame into the accumulator so a mid-stream snapshot
        # (resync) is coherent. Non-item frames only advance last_turn.
        state = self._store.get(sid)
        for frame in frames:
            state.apply(frame)
        return frames

    # -- turn helper -----------------------------------------------------
    def _ensure_turn(self, sid: str) -> list[Frame]:
        """Open a turn if none is active; emit its ``turn.started`` frame.

        Every content-bearing event guards through here, so a turn boundary is
        emitted even if a ``message.start`` was never seen (robustness).
        """
        ctx = self._ctx_for(sid)
        if ctx.current_turn is not None:
            return []
        ctx.turn_seq += 1
        ctx.current_turn = f"{sid}:t{ctx.turn_seq}"
        return [Frame(sid=sid, kind=FrameKind.TURN_STARTED, body={}, turn=ctx.current_turn)]

    def _ctx_for(self, sid: str) -> _Ctx:
        ctx = self._ctx.get(sid)
        if ctx is None:
            ctx = _Ctx()
            self._ctx[sid] = ctx
        return ctx

    def _new_item_id(self, sid: str) -> str:
        ctx = self._ctx_for(sid)
        ctx.item_seq += 1
        return f"{sid}:i{ctx.item_seq}"

    # -- message (agentMessage) ------------------------------------------
    def _reframe_message(self, event: GatewayEvent) -> list[Frame]:
        """message.start/delta/complete -> agentMessage item lifecycle + turn."""
        sid = event.session_id or ""
        ctx = self._ctx_for(sid)
        state = self._store.get(sid)

        if event.type == RawEvent.MESSAGE_START:
            # Pure turn boundary. The agentMessage item is created lazily at the
            # first message.delta so it sorts *after* any reasoning/tool items
            # that stream first within the turn.
            return self._ensure_turn(sid)

        if event.type == RawEvent.MESSAGE_DELTA:
            text = _text(event.payload)
            if not text:
                return []
            frames = self._ensure_turn(sid)
            if ctx.text_item is None:
                item_id = self._new_item_id(sid)
                ctx.text_item = item_id
                item = Item(
                    item_id=item_id,
                    type=ItemType.AGENT_MESSAGE,
                    status=ItemStatus.IN_PROGRESS,
                    ord=state.allocate_ord(),
                    body={"text": ""},
                )
                frames.append(Frame.with_item(sid, FrameKind.ITEM_STARTED, item, ctx.current_turn))
            frames.append(Frame.item_delta(sid, ctx.text_item, {"text": text}, ctx.current_turn))
            return frames

        # MESSAGE_COMPLETE — authoritative agentMessage + usage footer + turn end.
        frames = self._ensure_turn(sid)
        text = _text(event.payload)
        usage = event.payload.get("usage")

        if ctx.text_item is None:
            # A turn with no streamed text deltas (e.g. tool-only, or a summary
            # delivered whole). Materialize the item now so the turn has a body.
            item_id = self._new_item_id(sid)
            ctx.text_item = item_id
            ord_ = state.allocate_ord()
        else:
            item_id = ctx.text_item
            existing = state.items.get(item_id)
            ord_ = existing.ord if existing is not None else state.allocate_ord()

        done = Item(
            item_id=item_id,
            type=ItemType.AGENT_MESSAGE,
            status=ItemStatus.COMPLETED,
            ord=ord_,
            summary=_one_line(text),
            body={"text": text or ""},
        )
        frames.append(Frame.with_item(sid, FrameKind.ITEM_COMPLETED, done, ctx.current_turn))

        if isinstance(usage, dict) and usage:
            usage_item = Item(
                item_id=self._new_item_id(sid),
                type=ItemType.USAGE,
                status=ItemStatus.COMPLETED,
                ord=state.allocate_ord(),
                summary=_usage_summary(usage),
                body=dict(usage),
            )
            frames.append(Frame.with_item(sid, FrameKind.ITEM_COMPLETED, usage_item, ctx.current_turn))

        frames.append(
            Frame(
                sid=sid,
                kind=FrameKind.TURN_COMPLETED,
                body={"usage": usage} if isinstance(usage, dict) else {},
                turn=ctx.current_turn,
            )
        )
        # Close the turn — the next content event opens a fresh one.
        ctx.current_turn = None
        ctx.text_item = None
        ctx.reasoning_item = None
        return frames

    # -- reasoning -------------------------------------------------------
    def _reframe_reasoning(self, event: GatewayEvent) -> list[Frame]:
        """reasoning.delta/available -> reasoning item lifecycle."""
        sid = event.session_id or ""
        ctx = self._ctx_for(sid)
        state = self._store.get(sid)
        text = _text(event.payload)

        if event.type == RawEvent.REASONING_DELTA:
            if not text:
                return []
            frames = self._ensure_turn(sid)
            if ctx.reasoning_item is None:
                item_id = self._new_item_id(sid)
                ctx.reasoning_item = item_id
                item = Item(
                    item_id=item_id,
                    type=ItemType.REASONING,
                    status=ItemStatus.IN_PROGRESS,
                    ord=state.allocate_ord(),
                    body={"text": ""},
                )
                frames.append(Frame.with_item(sid, FrameKind.ITEM_STARTED, item, ctx.current_turn))
            frames.append(Frame.item_delta(sid, ctx.reasoning_item, {"text": text}, ctx.current_turn))
            return frames

        # REASONING_AVAILABLE — authoritative full reasoning text.
        frames = self._ensure_turn(sid)
        if ctx.reasoning_item is None:
            item_id = self._new_item_id(sid)
            ord_ = state.allocate_ord()
        else:
            item_id = ctx.reasoning_item
            existing = state.items.get(item_id)
            ord_ = existing.ord if existing is not None else state.allocate_ord()
        done = Item(
            item_id=item_id,
            type=ItemType.REASONING,
            status=ItemStatus.COMPLETED,
            ord=ord_,
            summary=_one_line(text),
            body={"text": text or ""},
        )
        frames.append(Frame.with_item(sid, FrameKind.ITEM_COMPLETED, done, ctx.current_turn))
        ctx.reasoning_item = None
        return frames

    # -- thinking (ephemeral) --------------------------------------------
    def _reframe_thinking(self, event: GatewayEvent) -> list[Frame]:
        """thinking.delta -> status frame (ephemeral 'formulating…' chatter).

        Not an ordered item: it is a placeholder animation the desktop shows
        while the model spins up. Surfaced as ``status`` so nothing is dropped,
        but it never pollutes the turn's item list.
        """
        sid = event.session_id or ""
        text = _text(event.payload)
        if not text:
            return []
        ctx = self._ctx_for(sid)
        return [
            Frame(sid=sid, kind=FrameKind.STATUS, body={"kind": "thinking", "text": text}, turn=ctx.current_turn)
        ]

    # -- tools -----------------------------------------------------------
    def _tool_item_id(
        self, ctx: _Ctx, sid: str, name: str, payload: dict, etype: str
    ) -> str:
        """Resolve the correlating ``item_id`` for a tool.start/complete.

        When the gateway supplies a ``tool_id`` it is reused verbatim as the
        item id, so start and complete correlate on it directly. When it is
        ABSENT (an edge the generic forward-compat path must still survive),
        synthesizing a fresh id on BOTH the start and the complete would split
        one tool across two cards — an orphaned in-progress card that never
        completes. Instead, correlate id-less events by tool ``name``: the start
        records its synthesized id under the name; the matching complete pops and
        reuses it. A complete with no prior start still gets a fresh id.
        """
        raw_tool_id = str(payload.get("tool_id") or "")
        if raw_tool_id:
            return raw_tool_id
        if etype == RawEvent.TOOL_START:
            item_id = self._new_item_id(sid)
            ctx.open_tools_by_name[name] = item_id
            return item_id
        # TOOL_COMPLETE with no tool_id: reuse the start's synthesized id if we
        # opened one for this name, else mint a fresh id (complete-without-start).
        return ctx.open_tools_by_name.pop(name, None) or self._new_item_id(sid)

    def _reframe_tool(self, event: GatewayEvent) -> list[Frame]:
        """tool.start/complete -> generic toolCall (or a special render type).

        ``tool_id`` is reused verbatim as the ``item_id`` so start and complete
        land on the same card. An unknown ``name`` still yields a valid toolCall.
        """
        sid = event.session_id or ""
        state = self._store.get(sid)
        ctx = self._ctx_for(sid)
        payload = event.payload
        name = str(payload.get("name") or "")
        # The task/todo list gets a dedicated taskList item on a stable id — not
        # a generic per-call toolCall card (protocol §2).
        if name == _TASK_TOOL:
            return self._reframe_tasks(event)
        tool_id = self._tool_item_id(ctx, sid, name, payload, event.type)
        itype = self._tool_item_type(name, payload)

        if event.type == RawEvent.TOOL_START:
            frames = self._ensure_turn(sid)
            body: dict[str, Any] = {"name": name}
            for key in ("context", "args_text", "args"):
                if payload.get(key) is not None:
                    body[key] = payload[key]
            item = Item(
                item_id=tool_id,
                type=itype,
                status=ItemStatus.IN_PROGRESS,
                ord=state.allocate_ord(),
                summary=_tool_summary(name, payload),
                body=body,
            )
            frames.append(Frame.with_item(sid, FrameKind.ITEM_STARTED, item, ctx.current_turn))
            return frames

        # TOOL_COMPLETE — authoritative tool result. May arrive with no prior
        # tool.start (progress disabled but an inline_diff forced the emit).
        frames = self._ensure_turn(sid)
        existing = state.items.get(tool_id)
        ord_ = existing.ord if existing is not None else state.allocate_ord()
        body = {"name": name}
        for key in ("args", "result", "duration_s", "inline_diff", "summary", "result_text", "todos", "context"):
            if payload.get(key) is not None:
                body[key] = payload[key]
        failed = _is_error_result(payload)
        item = Item(
            item_id=tool_id,
            type=ItemType.ERROR if failed else itype,
            status=ItemStatus.FAILED if failed else ItemStatus.COMPLETED,
            ord=ord_,
            summary=_tool_summary(name, payload),
            body=body,
        )
        frames.append(Frame.with_item(sid, FrameKind.ITEM_COMPLETED, item, ctx.current_turn))
        return frames

    # -- tasks / todos (dedicated taskList item) -------------------------
    def _tasks_item_id(self, sid: str) -> str:
        """The STABLE per-session id every task-list update lands on.

        Unlike a per-call toolCall (a fresh id each invocation), the task list is
        ONE living card: the first ``todo`` call is its snapshot and every later
        call updates the SAME id in place (protocol §2 "snapshot + subsequent
        updates keyed by a stable id").
        """
        return f"{sid}:tasks"

    def _reframe_tasks(self, event: GatewayEvent) -> list[Frame]:
        """``todo`` tool.start/complete -> a stable ``taskList`` item lifecycle.

        The gateway lifts the AUTHORITATIVE full list to a top-level ``todos``
        key on ``tool.complete``; ``tool.start`` may only carry a PARTIAL merge
        update in ``args.todos``. So the completed payload is authoritative
        (protocol §2/§4 completed-is-authoritative) and the start is a best-effort
        preview only. Lifecycle on the stable id:

        * first sight             -> ``item.started`` (in_progress snapshot)
        * subsequent, not all done -> ``item.delta`` (full authoritative list —
          a REPLACE, folded into the store so a resync snapshot stays current)
        * every task done/cancelled -> ``item.completed`` (authoritative, and the
          signal the Notifier turns into the task-list-complete push, §6)
        """
        sid = event.session_id or ""
        state = self._store.get(sid)
        ctx = self._ctx_for(sid)
        frames = self._ensure_turn(sid)
        payload = event.payload
        item_id = self._tasks_item_id(sid)
        existing = state.items.get(item_id)
        ord_ = existing.ord if existing is not None else state.allocate_ord()

        if event.type == RawEvent.TOOL_START:
            # A partial (merge) preview. Only materialize the card the first time
            # so the phone shows a pending list immediately; once a card exists,
            # keep the authoritative list intact and wait for the complete.
            if existing is not None:
                return frames
            tasks = _normalize_tasks(_start_tasks(payload))
            item = Item(
                item_id=item_id,
                type=ItemType.TASK_LIST,
                status=ItemStatus.IN_PROGRESS,
                ord=ord_,
                summary=_tasks_summary(tasks),
                body=_tasks_body(tasks, payload.get("summary")),
            )
            frames.append(Frame.with_item(sid, FrameKind.ITEM_STARTED, item, ctx.current_turn))
            return frames

        # TOOL_COMPLETE — the authoritative full list.
        tasks = _normalize_tasks(payload.get("todos"))
        body = _tasks_body(tasks, payload.get("summary"))
        summary = _tasks_summary(tasks)

        if _tasks_all_complete(tasks):
            # Idempotent completion. The taskList id is deliberately cross-turn
            # stable (``<sid>:tasks``), so a LATER turn can re-emit the SAME
            # already-complete list — agents defensively re-write the TodoWrite
            # list across turns. Re-emitting item.completed would fire a second
            # task_complete push: the Notifier dedupes per-turn
            # (notifier._identity keys on frame.turn), but this is the one item
            # type that is intentionally cross-turn, so a new turn defeats that
            # key and the user gets a repeated "Hermes finished its tasks"
            # banner for zero new work. When the stored card is already
            # COMPLETED with an identical task set, nothing changed: emit no
            # frame (the store already holds the authoritative completed item,
            # so a resync snapshot stays coherent).
            if (
                existing is not None
                and existing.status == ItemStatus.COMPLETED
                and existing.body.get("tasks") == tasks
            ):
                return frames
            item = Item(
                item_id=item_id,
                type=ItemType.TASK_LIST,
                status=ItemStatus.COMPLETED,
                ord=ord_,
                summary=summary,
                body=body,
            )
            frames.append(Frame.with_item(sid, FrameKind.ITEM_COMPLETED, item, ctx.current_turn))
        elif existing is None or existing.status != ItemStatus.IN_PROGRESS:
            # First sight (progress disabled -> only a complete arrives), OR a
            # previously-completed list reopened with new work: (re)materialize
            # the card in_progress via item.started (wholesale replace in store).
            item = Item(
                item_id=item_id,
                type=ItemType.TASK_LIST,
                status=ItemStatus.IN_PROGRESS,
                ord=ord_,
                summary=summary,
                body=body,
            )
            frames.append(Frame.with_item(sid, FrameKind.ITEM_STARTED, item, ctx.current_turn))
        else:
            # Living in-progress card: a full-list REPLACE delta. The patch keys
            # (``tasks``/``counts``) shallow-overwrite the item body in the store
            # (session_state._merge_patch), so a mid-stream snapshot stays
            # authoritative; the phone repaints the list from ``body.tasks``.
            frames.append(Frame.item_delta(sid, item_id, body, ctx.current_turn))
        return frames

    # -- error -----------------------------------------------------------
    def _reframe_error(self, event: GatewayEvent) -> list[Frame]:
        """error -> error item (never hidden in a collapse, protocol §2)."""
        sid = event.session_id or ""
        state = self._store.get(sid)
        frames = self._ensure_turn(sid)
        ctx = self._ctx_for(sid)
        message = str(event.payload.get("message") or event.payload.get("text") or "error")
        item = Item(
            item_id=self._new_item_id(sid),
            type=ItemType.ERROR,
            status=ItemStatus.FAILED,
            ord=state.allocate_ord(),
            summary=_one_line(message),
            body={"message": message},
        )
        frames.append(Frame.with_item(sid, FrameKind.ITEM_COMPLETED, item, ctx.current_turn))
        return frames

    # -- status ----------------------------------------------------------
    def _reframe_status(self, event: GatewayEvent) -> list[Frame]:
        """status.update -> status frame (non-item lifecycle chatter)."""
        sid = event.session_id or ""
        ctx = self._ctx_for(sid)
        payload = event.payload
        return [
            Frame(
                sid=sid,
                kind=FrameKind.STATUS,
                body={"kind": str(payload.get("kind") or "status"), "text": str(payload.get("text") or "")},
                turn=ctx.current_turn,
            )
        ]

    # -- title -----------------------------------------------------------
    def _reframe_title(self, event: GatewayEvent) -> list[Frame]:
        """session.title/title -> title frame (session title changed)."""
        sid = event.session_id or ""
        title = str(event.payload.get("title") or "")
        return [Frame(sid=sid, kind=FrameKind.TITLE, body={"title": title})]

    # -- interactive gates -----------------------------------------------
    def _reframe_interactive(self, event: GatewayEvent, kind: str) -> list[Frame]:
        """approval.request / clarify.request -> interactive gate frame.

        Passed through as the frame body verbatim (already redacted upstream by
        the gateway for approvals). The phone replies via an upstream RPC.
        """
        sid = event.session_id or ""
        ctx = self._ctx_for(sid)
        return [Frame(sid=sid, kind=kind, body=dict(event.payload), turn=ctx.current_turn)]

    # -- unknown (forward-compat, never drop) ----------------------------
    def _reframe_unknown(self, event: GatewayEvent) -> list[Frame]:
        """An unrecognized event becomes a generic toolCall — never dropped."""
        sid = event.session_id or ""
        state = self._store.get(sid)
        frames = self._ensure_turn(sid)
        ctx = self._ctx_for(sid)
        item = Item(
            item_id=self._new_item_id(sid),
            type=ItemType.TOOL_CALL,
            status=ItemStatus.COMPLETED,
            ord=state.allocate_ord(),
            summary=event.type,
            body={"event_type": event.type, "payload": dict(event.payload)},
        )
        frames.append(Frame.with_item(sid, FrameKind.ITEM_COMPLETED, item, ctx.current_turn))
        return frames

    # -- type selection --------------------------------------------------
    @staticmethod
    def _tool_item_type(name: str, payload: dict) -> str:
        """Select the item type for a tool by name/result (protocol §2 rule).

        ``inline_diff`` present -> fileChange; ``browser_*`` -> browser; known
        image tool -> image; otherwise the generic toolCall. Never raises on an
        unknown name.
        """
        if payload.get("inline_diff"):
            return ItemType.FILE_CHANGE
        if name.startswith(_BROWSER_PREFIX):
            return ItemType.BROWSER
        if name in _IMAGE_TOOLS:
            return ItemType.IMAGE
        return ItemType.TOOL_CALL


# ---------------------------------------------------------------------------
# Small pure helpers (payload normalization / summary lines).
# ---------------------------------------------------------------------------


def _text(payload: dict[str, Any]) -> str:
    """Extract the streaming ``text`` field, tolerant of shape drift."""
    val = payload.get("text")
    return val if isinstance(val, str) else ""


def _one_line(text: str, limit: int = 120) -> str:
    """First non-empty line of ``text``, clipped — the item card summary."""
    if not text or not text.strip():
        return ""
    return text.strip().splitlines()[0][:limit]


def _tool_summary(name: str, payload: dict[str, Any]) -> str:
    """One-line tool card summary — prefer the gateway's own ``summary``/``context``."""
    for key in ("summary", "context"):
        val = payload.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip()[:120]
    return name


def _usage_summary(usage: dict[str, Any]) -> str:
    total = usage.get("total")
    return f"{total} tokens" if isinstance(total, int) else "usage"


def _start_tasks(payload: dict[str, Any]) -> Any:
    """The partial task list on a ``todo`` tool.start (``args.todos``), if any."""
    args = payload.get("args")
    if isinstance(args, dict):
        return args.get("todos")
    return None


def _normalize_tasks(raw: Any) -> list[dict[str, Any]]:
    """Normalize the gateway's ``{id,content,status}`` todos to ``{id,text,status}``.

    Tolerant of shape drift: non-list -> empty; non-dict entries dropped; a
    missing text falls back to ``content`` (the gateway's field name); status
    defaults to ``pending``. The phone renders from this stable trio.
    """
    if not isinstance(raw, list):
        return []
    out: list[dict[str, Any]] = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        text = entry.get("text")
        if not isinstance(text, str) or not text:
            text = entry.get("content")
        out.append(
            {
                "id": str(entry.get("id", "")),
                "text": str(text or ""),
                "status": str(entry.get("status") or "pending"),
            }
        )
    return out


def _tasks_counts(tasks: list[dict[str, Any]]) -> dict[str, int]:
    """Per-status tallies + total for the task-list card badge."""
    counts = {"total": len(tasks)}
    for status in _TASK_STATUSES:
        counts[status] = 0
    for task in tasks:
        status = task.get("status")
        if status in counts:
            counts[status] += 1
    return counts


def _tasks_all_complete(tasks: list[dict[str, Any]]) -> bool:
    """True iff the list is non-empty and every task is done/cancelled."""
    return bool(tasks) and all(t.get("status") in _TASK_DONE_STATUSES for t in tasks)


def _tasks_summary(tasks: list[dict[str, Any]]) -> str:
    """Card summary like ``Tasks 2/5`` (done/total)."""
    counts = _tasks_counts(tasks)
    done = counts["completed"] + counts["cancelled"]
    return f"Tasks {done}/{counts['total']}"


def _tasks_body(tasks: list[dict[str, Any]], tool_summary: Any = None) -> dict[str, Any]:
    """The ``taskList`` item body: the full list + per-status counts.

    ``all_complete`` is a convenience flag the Notifier reads without re-deriving
    it; the gateway's own ``summary`` (if present) is preserved under
    ``tool_summary`` for parity with the desktop card.
    """
    body: dict[str, Any] = {
        "tasks": tasks,
        "counts": _tasks_counts(tasks),
        "all_complete": _tasks_all_complete(tasks),
    }
    if isinstance(tool_summary, dict):
        body["tool_summary"] = tool_summary
    return body


def _is_error_result(payload: dict[str, Any]) -> bool:
    """A tool.complete is a failure when its result carries an explicit error."""
    if payload.get("is_error"):
        return True
    result = payload.get("result")
    if isinstance(result, dict):
        return bool(result.get("error") or result.get("is_error"))
    return False
