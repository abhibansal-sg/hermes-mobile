"""Shared types for the mobile relay — the frozen wire + internal contract.

This module is the single source of truth the four build lanes (GatewayClient,
Reframer, DownstreamServer, Notifier) all import. Nothing here has behavior
beyond serialization/normalization: it is the *shape* layer. It implements the
ratified ``docs/RELAY-PHONE-PROTOCOL.md`` v1 contract plus the internal event
shapes the lanes exchange over the in-process :mod:`hermes_relay.bus`.

Three coordinate systems live here, kept deliberately distinct:

1. **Downstream wire** (relay -> phone): :class:`Frame` — the
   ``{seq, sid, turn, kind, body}`` envelope (protocol §1) whose ``body`` for
   item frames is an :class:`Item` (§2). ``seq`` is stamped LATE by the
   DownstreamServer/ReplayRing, so a Frame carries ``seq is None`` until then.
2. **Upstream wire** (phone -> relay): :class:`UpstreamRequest` — ordinary
   JSON-RPC-2.0 (§1) with method in :data:`UpstreamMethod`.
3. **Raw gateway** (gateway -> relay): :class:`GatewayEvent` — the inbound
   ``event`` frame the GatewayClient demuxes off one WS (``type``,
   ``session_id``, ``payload``). The Reframer's whole job is (3) -> (1).

The seq/ack/replay reliability spine (protocol §4) is NOT modeled here; it is
owned by ``plugins/hermes-mobile/replay_ring.py`` (reused verbatim) and driven
by the DownstreamServer.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Optional


# ---------------------------------------------------------------------------
# Enumerations (kept as plain str constants so they serialize transparently and
# an unknown value never raises — forward-compat is a protocol requirement).
# ---------------------------------------------------------------------------


class FrameKind:
    """Downstream frame kinds (protocol §3). The ``kind`` field of :class:`Frame`."""

    ITEM_STARTED = "item.started"
    ITEM_DELTA = "item.delta"
    ITEM_COMPLETED = "item.completed"
    TURN_STARTED = "turn.started"
    TURN_COMPLETED = "turn.completed"
    APPROVAL_REQUEST = "approval.request"
    CLARIFY_REQUEST = "clarify.request"
    STATUS = "status"
    TITLE = "title"
    SNAPSHOT = "snapshot"

    ALL = frozenset(
        {
            ITEM_STARTED,
            ITEM_DELTA,
            ITEM_COMPLETED,
            TURN_STARTED,
            TURN_COMPLETED,
            APPROVAL_REQUEST,
            CLARIFY_REQUEST,
            STATUS,
            TITLE,
            SNAPSHOT,
        }
    )


class ItemType:
    """Item types (protocol §2). The generic backbone + special renders.

    An unknown/new type MUST be rendered by the client as a generic
    :data:`TOOL_CALL` card (protocol §2 forward-compat rule); the Reframer
    assigns the type from the raw event / tool ``name``.
    """

    USER_MESSAGE = "userMessage"
    AGENT_MESSAGE = "agentMessage"
    REASONING = "reasoning"
    TOOL_CALL = "toolCall"  # GENERIC — any tool.start/complete keyed by name
    TASK_LIST = "taskList"  # the agent's structured task/todo list (id,text,status)
    FILE_CHANGE = "fileChange"
    IMAGE = "image"
    BROWSER = "browser"
    ERROR = "error"
    USAGE = "usage"

    ALL = frozenset(
        {
            USER_MESSAGE,
            AGENT_MESSAGE,
            REASONING,
            TOOL_CALL,
            TASK_LIST,
            FILE_CHANGE,
            IMAGE,
            BROWSER,
            ERROR,
            USAGE,
        }
    )


class ItemStatus:
    """Item lifecycle status (protocol §2). ``completed`` is authoritative."""

    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    FAILED = "failed"


class UpstreamMethod:
    """Phone -> relay JSON-RPC methods (protocol §1/§5).

    The DownstreamServer translates each to gateway RPC(s) per the §5 mapping;
    ``ACK`` and ``RESYNC`` are handled locally by the ReplayRing (never reach
    the gateway).
    """

    SUBMIT = "submit"          # -> session.create/resume (+own) -> prompt.submit
    RESUME = "resume"          # -> session.resume (own an idle/foreign session)
    OPEN = "open"              # -> REST GET /messages (store-read, no reactivation)
    LIST = "list"              # -> session.list (pass-through)
    HISTORY = "history"        # -> REST GET /messages (R0 correction: NOT session.history)
    APPROVE = "approve"        # -> approval.respond (pass-through)
    CLARIFY = "clarify"        # -> clarify.respond (pass-through)
    INTERRUPT = "interrupt"    # -> session.interrupt (pass-through)
    STEER = "steer"            # -> session.steer (pass-through; QA-2 R11: live-turn steering over relay)
    ATTACH = "attach"         # -> file.attach / image.attach_bytes (bytes inlined as a data: URL; REST-free attach, B9/A5)
    ACK = "ack"               # local: ring.drop acked frames {through}
    RESYNC = "resync"         # local: ring.decide {last_seq} -> replay or snapshot
    FOREGROUND = "foreground"  # local: phone declares the session it now holds foregrounded (§6 gate); null clears
    PUSH_REGISTER = "push.register"    # local: register the APNs device token in the relay's push registry (§6)
    PUSH_UNREGISTER = "push.unregister"  # local: remove the APNs device token from the relay's push registry (§6)

    ALL = frozenset(
        {SUBMIT, RESUME, OPEN, LIST, HISTORY, APPROVE, CLARIFY, INTERRUPT, STEER, ATTACH, ACK, RESYNC, FOREGROUND,
         PUSH_REGISTER, PUSH_UNREGISTER}
    )


# Raw gateway event types observed on the wire in the R0 spike (VERDICT.md) plus
# the catalog in RELAY-PHONE-PROTOCOL.md §2. The Reframer switches on these.
class RawEvent:
    """Gateway ``event.params.type`` values the Reframer maps from (§2, R0)."""

    GATEWAY_READY = "gateway.ready"
    SESSION_INFO = "session.info"          # per-session model/tool metadata (non-turn)
    MESSAGE_START = "message.start"        # payload is null on the wire -> turn boundary
    MESSAGE_DELTA = "message.delta"        # payload.text
    MESSAGE_COMPLETE = "message.complete"  # payload.{text,usage,reasoning,status} (authoritative)
    REASONING_DELTA = "reasoning.delta"    # payload.text
    REASONING_AVAILABLE = "reasoning.available"  # payload.text (authoritative reasoning)
    THINKING_DELTA = "thinking.delta"      # payload.text — ephemeral "formulating…" chatter
    TOOL_START = "tool.start"              # payload.{tool_id,name,context,args_text?}
    TOOL_COMPLETE = "tool.complete"        # payload.{tool_id,name,args,result,duration_s,summary,inline_diff}
    STATUS_UPDATE = "status.update"        # payload.{kind,text}
    SESSION_TITLE = "session.title"        # payload.{session_id,title}
    TITLE = "title"                        # alias some emitters use for a title change
    APPROVAL_REQUEST = "approval.request"  # payload.{command,choices,...} interactive gate
    CLARIFY_REQUEST = "clarify.request"    # payload.{question,choices} interactive gate
    ERROR = "error"                        # payload.{message}


# ---------------------------------------------------------------------------
# Item (protocol §2) — the unit the phone renders.
# ---------------------------------------------------------------------------


@dataclass
class Item:
    """One ordered turn item with a stable ``item_id`` and a lifecycle.

    Lifecycle: ``started -> delta* -> completed`` where ``completed`` REPLACES
    whatever the deltas accumulated (authoritative). ``body`` is
    type-specific and free-form (args/result for a toolCall, markdown text for
    an agentMessage, usage dict for a usage item, etc.).
    """

    item_id: str
    type: str
    status: str = ItemStatus.IN_PROGRESS
    ord: int = 0
    summary: str = ""
    body: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "item_id": self.item_id,
            "type": self.type,
            "status": self.status,
            "ord": self.ord,
            "summary": self.summary,
            "body": self.body,
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Item":
        return cls(
            item_id=d["item_id"],
            type=d.get("type", ItemType.TOOL_CALL),
            status=d.get("status", ItemStatus.IN_PROGRESS),
            ord=int(d.get("ord", 0)),
            summary=d.get("summary", ""),
            body=dict(d.get("body") or {}),
        )


# ---------------------------------------------------------------------------
# Frame (protocol §1/§3) — the downstream envelope, relay -> phone.
# ---------------------------------------------------------------------------


@dataclass
class Frame:
    """A downstream envelope ``{seq, sid, turn, kind, body}`` (protocol §1).

    ``seq`` is ``None`` when the Reframer emits it; the DownstreamServer stamps
    the monotonic per-connection seq (protocol §4) at send time via the replay
    ring. ``body`` is a plain dict on the wire — for item frames it is an
    :class:`Item` dict (use :meth:`item_body` / :meth:`with_item`).
    """

    sid: str
    kind: str
    body: dict[str, Any] = field(default_factory=dict)
    turn: Optional[str] = None
    seq: Optional[int] = None

    # -- item convenience -------------------------------------------------
    @classmethod
    def with_item(cls, sid: str, kind: str, item: Item, turn: Optional[str] = None) -> "Frame":
        """Build an item.* frame whose body is the full item dict."""
        return cls(sid=sid, kind=kind, body=item.to_dict(), turn=turn)

    @classmethod
    def item_delta(
        cls, sid: str, item_id: str, patch: dict[str, Any], turn: Optional[str] = None
    ) -> "Frame":
        """Build an ``item.delta`` frame (body = ``{item_id, patch}``, §3)."""
        return cls(
            sid=sid,
            kind=FrameKind.ITEM_DELTA,
            body={"item_id": item_id, "patch": patch},
            turn=turn,
        )

    def to_wire(self) -> dict[str, Any]:
        """Serialize for the phone socket. Requires ``seq`` to be stamped."""
        if self.seq is None:
            raise ValueError("Frame.to_wire() called before seq was stamped")
        return {
            "seq": self.seq,
            "sid": self.sid,
            "turn": self.turn,
            "kind": self.kind,
            "body": self.body,
        }

    @classmethod
    def from_wire(cls, d: dict[str, Any]) -> "Frame":
        return cls(
            sid=d.get("sid", ""),
            kind=d["kind"],
            body=dict(d.get("body") or {}),
            turn=d.get("turn"),
            seq=d.get("seq"),
        )


# ---------------------------------------------------------------------------
# Upstream request (protocol §1/§5) — phone -> relay JSON-RPC-2.0.
# ---------------------------------------------------------------------------


@dataclass
class UpstreamRequest:
    """A parsed phone -> relay JSON-RPC-2.0 request.

    ``id`` is echoed on the JSON-RPC response the DownstreamServer sends back
    (``None`` for notifications such as ``ack``). ``method`` is one of
    :data:`UpstreamMethod`.
    """

    method: str
    params: dict[str, Any] = field(default_factory=dict)
    id: Optional[int] = None

    @classmethod
    def from_wire(cls, d: dict[str, Any]) -> "UpstreamRequest":
        return cls(
            method=d.get("method", ""),
            params=dict(d.get("params") or {}),
            id=d.get("id"),
        )


# ---------------------------------------------------------------------------
# Raw gateway event (gateway -> relay) — the Reframer's input.
# ---------------------------------------------------------------------------


@dataclass
class GatewayEvent:
    """One inbound gateway ``event`` frame, demuxed off the single WS.

    Mirrors the R0 spike's observed shape:
    ``{"method":"event","params":{"type","session_id","payload"}}``. ``ts`` is
    a monotonic relay-local receive timestamp (seconds) for ordering/diagnostics.
    """

    type: str
    session_id: Optional[str]
    payload: dict[str, Any] = field(default_factory=dict)
    ts: float = field(default_factory=time.monotonic)

    @classmethod
    def from_rpc_params(cls, params: dict[str, Any]) -> "GatewayEvent":
        return cls(
            type=params.get("type", ""),
            session_id=params.get("session_id"),
            payload=dict(params.get("payload") or {}),
        )
