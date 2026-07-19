"""Revisioned HRP/2 projection built from the existing Gateway Reframer."""

from __future__ import annotations

import copy
from typing import Any, Mapping

from ..types import Frame, FrameKind
from .storage import RelayStorage, random_id


class V2Projection:
    """Translate v1 lane frames into replay-safe revisioned HRP/2 frames.

    The v1 mapping remains useful, but none of its append semantics become v2
    authority.  This adapter assigns a durable random item ID and records every
    revision before a DeviceRouter can encrypt it.
    """

    def __init__(self, storage: RelayStorage) -> None:
        self.storage = storage

    def apply(self, frame: Frame | Mapping[str, Any]) -> dict[str, Any] | None:
        if isinstance(frame, Frame):
            sid, turn, kind, body = frame.sid, frame.turn, frame.kind, frame.body
        else:
            sid = str(frame.get("sid", ""))
            turn = frame.get("turn")
            kind = str(frame.get("kind", ""))
            raw_body = frame.get("body") or {}
            if not isinstance(raw_body, Mapping):
                return None
            body = dict(raw_body)
        if not sid or not kind:
            return None

        if kind in {FrameKind.ITEM_STARTED, FrameKind.ITEM_COMPLETED}:
            return self._full(sid, turn, kind, body)
        if kind == FrameKind.ITEM_DELTA:
            return self._delta(sid, turn, body)
        return {"sid": sid, "turn": turn, "kind": kind, "body": copy.deepcopy(body)}

    def next_ord(self, session_id: str) -> int:
        """Return an append position before starting a Gateway prompt.

        Prompt submission can synchronously produce Gateway events before its
        RPC response arrives.  Taking the position first keeps the user's item
        ordered ahead of those response items even though it becomes
        authoritative only after the Gateway accepts the prompt.
        """

        items = self.storage.session_checkpoint(session_id)["items"]
        return max((int(item["ord"]) for item in items), default=-1) + 1

    def validate_user_message(
        self,
        session_id: str,
        client_message_id: str,
        text: str,
    ) -> None:
        """Reject local receipt-ID reuse with different user content."""

        current = self.storage.session_item(session_id, client_message_id)
        if current is None:
            return
        if not (
            current["type"] == "userMessage"
            and current["status"] == "completed"
            and current["body"] == {"text": text}
        ):
            raise ValueError("client_message_id request conflict")

    def authoritative_user_frame(
        self,
        session_id: str,
        client_message_id: str,
        text: str,
        *,
        ord_: int,
    ) -> dict[str, Any]:
        """Persist and return the canonical user item for an accepted prompt.

        ``client_message_id`` is deliberately the item ID.  This is the bridge
        that lets a device reconcile its optimistic local echo with the
        Agent's durable projection and with later checkpoints.
        """

        self.validate_user_message(session_id, client_message_id, text)
        current = self.storage.session_item(session_id, client_message_id)
        if current is None:
            item = {
                "item_id": client_message_id,
                "session_id": session_id,
                "turn_id": None,
                "type": "userMessage",
                "status": "completed",
                "ord": ord_,
                "rev": 1,
                "summary": text[:200],
                "body": {"text": text},
            }
            self.storage.put_full_item(
                session_id,
                item,
                source_item_id=client_message_id,
            )
        else:
            item = current
        return {
            "sid": session_id,
            "turn": item["turn_id"],
            "kind": FrameKind.ITEM_COMPLETED,
            "body": item,
        }

    def _full(
        self,
        sid: str,
        turn: Any,
        kind: str,
        body: Mapping[str, Any],
    ) -> dict[str, Any] | None:
        source_id = str(body.get("item_id", ""))
        if not source_id:
            return None
        item_id = self.storage.resolve_item_id(sid, source_id) or random_id("itm")
        current = self.storage.session_item(sid, item_id)
        normalized_body = copy.deepcopy(body.get("body") or {})
        status = str(body.get("status", "in_progress"))
        type_ = str(body.get("type", "unknown"))
        summary = str(body.get("summary", ""))
        # Gateway/Reframer ordinals restart with the process and therefore are
        # not a durable session coordinate.  Assign each new live item after
        # the persisted projection and retain that position for all revisions.
        ord_ = int(current["ord"]) if current else self.next_ord(sid)
        if current is not None and all((
            current["body"] == normalized_body,
            current["status"] == status,
            current["type"] == type_,
            current["summary"] == summary,
            current["ord"] == ord_,
        )):
            return None
        revision = int(current["rev"] + 1) if current else 1
        item = {
            "item_id": item_id,
            "session_id": sid,
            "turn_id": turn,
            "type": type_,
            "status": status,
            "ord": ord_,
            "rev": revision,
            "summary": summary,
            "body": normalized_body,
        }
        self.storage.put_full_item(sid, item, source_item_id=source_id)
        return {"sid": sid, "turn": turn, "kind": kind, "body": item}

    def _delta(
        self,
        sid: str,
        turn: Any,
        body: Mapping[str, Any],
    ) -> dict[str, Any] | None:
        source_id = str(body.get("item_id", ""))
        item_id = self.storage.resolve_item_id(sid, source_id) if source_id else None
        if item_id is None:
            return None
        current = self.storage.session_item(sid, item_id)
        if current is None or current["status"] != "in_progress":
            return None
        patch = body.get("patch") or {}
        if not isinstance(patch, Mapping):
            return None

        # The only append operation has byte-exact conflict semantics.  More
        # complex tool/list patches become a higher-revision full item so they
        # are still idempotent without inventing an unsafe generic JSON patch.
        text = patch.get("text", patch.get("delta"))
        only_text = set(patch) <= {"text", "delta"}
        if isinstance(text, str) and only_text:
            old_text = current["body"].get("text", "")
            if not isinstance(old_text, str):
                return None
            delta = {
                "item_id": item_id,
                "from_rev": current["rev"],
                "to_rev": current["rev"] + 1,
                "ops": [
                    {
                        "op": "append_utf8",
                        "path": "/body/text",
                        "offset": len(old_text.encode("utf-8")),
                        "data": text,
                    }
                ],
            }
            if self.storage.apply_item_delta(sid, delta) != "applied":
                return None
            return {
                "sid": sid,
                "turn": turn,
                "kind": FrameKind.ITEM_DELTA,
                "body": delta,
            }

        updated = copy.deepcopy(current)
        updated["rev"] = current["rev"] + 1
        next_body = dict(current["body"])
        for key, value in patch.items():
            if key == "summary" and isinstance(value, str):
                updated["summary"] = str(current["summary"]) + value
            else:
                next_body[key] = copy.deepcopy(value)
        updated["body"] = next_body
        updated["turn_id"] = turn
        self.storage.put_full_item(sid, updated, source_item_id=source_id)
        return {
            "sid": sid,
            "turn": turn,
            "kind": FrameKind.ITEM_STARTED,
            "body": updated,
        }

    def checkpoint(
        self,
        session_id: str,
        *,
        stream_id: str,
        through_seq: int,
        snapshot_revision: int,
    ) -> dict[str, Any]:
        snapshot = self.storage.session_checkpoint(session_id)
        return {
            **snapshot,
            "stream_id": stream_id,
            "through_seq": through_seq,
            "snapshot_revision": snapshot_revision,
            "replace": True,
        }

    def import_gateway_history(
        self, session_id: str, messages: list[Mapping[str, Any]]
    ) -> dict[str, Any]:
        """Replace the local projection from authoritative store-read history."""

        current_checkpoint = self.storage.session_checkpoint(session_id)
        items: list[dict[str, Any]] = []
        for order, message in enumerate(messages):
            source_id = str(
                message.get("id") or message.get("message_id") or f"history-{order}"
            )
            item_id = self.storage.resolve_item_id(session_id, source_id) or random_id(
                "itm"
            )
            current = self.storage.session_item(session_id, item_id)
            role = str(message.get("role") or "unknown")
            type_ = {
                "user": "userMessage",
                "assistant": "agentMessage",
                "system": "reasoning",
                "tool": "toolCall",
            }.get(role, "toolCall")
            text = _history_text(message)
            body = {"text": text, "role": role}
            candidate = {
                "item_id": item_id,
                "session_id": session_id,
                "turn_id": None,
                "type": type_,
                "status": "completed",
                "ord": order,
                "summary": text[:200],
                "body": body,
            }
            unchanged = current is not None and all(
                current.get(key) == candidate[key]
                for key in (
                    "session_id",
                    "turn_id",
                    "type",
                    "status",
                    "ord",
                    "summary",
                    "body",
                )
            )
            candidate["rev"] = (
                current["rev"]
                if unchanged
                else (
                    current["rev"] + 1
                    if current
                    else max(1, int(current_checkpoint["snapshot_revision"]) + 1)
                )
            )
            self.storage.put_full_item(session_id, candidate, source_item_id=source_id)
            items.append(candidate)

        snapshot_revision = max(
            int(current_checkpoint["snapshot_revision"]) + 1,
            max((int(item["rev"]) for item in items), default=1),
        )
        self.storage.apply_checkpoint(
            session_id,
            snapshot_revision=snapshot_revision,
            through_seq=int(current_checkpoint["through_seq"]),
            replace=True,
            items=items,
            tombstones=[],
        )
        return self.storage.session_checkpoint(session_id)


def _history_text(message: Mapping[str, Any]) -> str:
    value = message.get("text", message.get("content", ""))
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts: list[str] = []
        for part in value:
            if isinstance(part, str):
                parts.append(part)
            elif isinstance(part, Mapping) and isinstance(part.get("text"), str):
                parts.append(part["text"])
        return "\n".join(parts)
    # Never serialize arbitrary reprs (which may contain secrets or unstable
    # object addresses) into the protocol projection.
    return ""


__all__ = ["V2Projection"]
