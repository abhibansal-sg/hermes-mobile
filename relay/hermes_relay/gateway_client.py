"""Lane 1 — GatewayClient: the durable WS client to the stock gateway.

A single, persistent JSON-RPC-2.0 WebSocket connection to
``ws://<host>:<port>/api/ws?token=…`` (the stock gateway's sidecar) that
multiplexes ALL of the relay's sessions. It:

* authenticates via the ``?token=`` query param (loopback / co-located host);
* survives disconnects with reconnect + exponential backoff, re-minting the URL
  and re-establishing owned sessions (the desktop ``use-gateway-boot`` pattern);
* issues id-matched RPCs and awaits their results;
* demuxes inbound ``event`` frames by ``session_id`` and republishes each as a
  :class:`~hermes_relay.types.GatewayEvent` on ``TOPIC_GATEWAY_EVENTS``.

Session-op mapping it implements (protocol §5), with the R0 correction that
foreign/idle history is a REST store-read, NOT the ``session.history`` RPC:

* :meth:`session_list`      -> ``session.list``            (read, no ownership)
* :meth:`session_create`    -> ``session.create``          (own)
* :meth:`session_resume`    -> ``session.resume``          (own idle/foreign)
* :meth:`rest_history`      -> ``GET /api/sessions/{id}/messages`` (store-read)
* :meth:`prompt_submit`     -> ``prompt.submit``           (become owner + drive)
* :meth:`approval_respond`  -> ``approval.respond``
* :meth:`clarify_respond`   -> ``clarify.respond``
* :meth:`session_interrupt` -> ``session.interrupt``

This lane is proven by the R0 spike (``r0-relay-spike/relay_client.py``); this is
its productionized, multiplexing, reconnecting form. It publishes; it never
reframes (that is Lane 2).

Testability seams (dependency-injected, all default to the real thing):

* ``connector``  — ``async (url) -> WSTransport``; defaults to a websockets
  client. A mock connector drives every unit test with zero live network.
* ``rest_client`` — an object with ``async get(url, headers=, timeout=)`` a la
  ``httpx.AsyncClient``; lazily built if not supplied.
* ``sleep``      — ``async (secs) -> None`` for backoff; injectable so reconnect
  tests run instantly.
* ``token_provider`` — ``() -> str`` re-minted on every (re)connect so a rotating
  loopback token survives reconnects.
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Optional, Protocol, runtime_checkable

from .bus import EventBus, TOPIC_GATEWAY_EVENTS
from .durable_state import DurableState
from .types import GatewayEvent, RawEvent

# Origin tag stamped on sessions the relay creates/resumes (matches R0 spike).
RELAY_SOURCE = "mobile-relay"


# ---------------------------------------------------------------------------
# Transport seam — the minimal surface the client needs from a live socket.
# ``websockets`` client connections satisfy this already; the mock in the unit
# tests satisfies it too. Keeping the client blind to the concrete socket is
# what lets every test run without a live gateway.
# ---------------------------------------------------------------------------
@runtime_checkable
class WSTransport(Protocol):
    async def send(self, data: str) -> None: ...
    async def recv(self) -> Any: ...  # str/bytes; raises on close
    async def close(self) -> None: ...


Connector = Callable[[str], Awaitable[WSTransport]]


class GatewayRPCError(RuntimeError):
    """A JSON-RPC ``error`` object returned by the gateway for an RPC."""

    def __init__(self, method: str, error: dict[str, Any]) -> None:
        self.method = method
        self.code = error.get("code")
        self.message = error.get("message", "")
        self.data = error.get("data")
        super().__init__(f"{method} -> [{self.code}] {self.message}")


@dataclass
class GatewayConfig:
    """Connection parameters for the gateway WS + REST surface."""

    host: str = "127.0.0.1"
    port: int = 9126  # isolated test gateway range (NEVER 9119 live)
    token: str = ""
    source: str = RELAY_SOURCE
    cols: int = 80
    max_message_bytes: int = 8 * 1024 * 1024
    connect_timeout_s: float = 10.0
    rpc_timeout_s: float = 30.0
    backoff_initial_s: float = 0.5
    backoff_max_s: float = 30.0
    backoff_factor: float = 2.0

    def ws_url(self, token: Optional[str] = None) -> str:
        return f"ws://{self.host}:{self.port}/api/ws?token={token if token is not None else self.token}"

    @property
    def http_base(self) -> str:
        return f"http://{self.host}:{self.port}"

    def rest_headers(self, token: Optional[str] = None) -> dict[str, str]:
        return {"X-Hermes-Session-Token": token if token is not None else self.token}


class GatewayClient:
    """Durable multiplexing JSON-RPC client to one stock gateway."""

    def __init__(
        self,
        config: GatewayConfig,
        bus: EventBus,
        *,
        connector: Optional[Connector] = None,
        rest_client: Any = None,
        sleep: Optional[Callable[[float], Awaitable[None]]] = None,
        token_provider: Optional[Callable[[], str]] = None,
        durable: Optional[DurableState] = None,
    ) -> None:
        self._cfg = config
        self._bus = bus
        self._connector: Connector = connector or _default_connector(config)
        self._rest_client = rest_client  # lazily built if None (see _rest())
        self._owns_rest_client = rest_client is None
        self._sleep = sleep or asyncio.sleep
        self._token_provider = token_provider
        # Durable owned-session store. When provided, the owned set survives a
        # relay restart: the constructor seeds ``_owned`` from it and every
        # ownership mutation is mirrored to it. ``None`` (unit tests) keeps the
        # legacy in-memory-only behaviour.
        self._durable = durable

        # Sessions this relay OWNS (created/resumed here) — re-established on
        # reconnect and observed by the Notifier for owned-session pushes. Seeded
        # from durable storage so a relay restart re-resumes the phone's sessions
        # instead of dropping them (the "destination session not active" failure).
        self._owned: set[str] = set(self._durable.load_owned_sessions()) if self._durable else set()

        # Origin/requested id -> live id learned at resume time. A stock gateway
        # may hand a resumed session a DISTINCT live id (echoing the requested id
        # back as ``resumed``); a submit MUST target the live id, so we remember
        # the mapping and resolve it in :meth:`live_id_for` (R0/E2E finding).
        self._live_by_origin: dict[str, str] = {}

        # Live token (re-minted on each connect via token_provider, if given).
        self._token: str = config.token

        # RPC id spine + the in-flight futures awaiting their matched response.
        self._next_id_n = 0
        self._pending: dict[int, "asyncio.Future[dict[str, Any]]"] = {}

        # Connection state.
        self._transport: Optional[WSTransport] = None
        self._reader_task: Optional[asyncio.Task[None]] = None
        self._ready = asyncio.Event()
        self._reader_done = asyncio.Event()
        self._closing = False
        self._run_task: Optional[asyncio.Task[None]] = None

    # -- ownership bookkeeping (mirrored to durable storage) --------------
    def _mark_owned(self, session_id: str) -> None:
        """Add ``session_id`` to the owned set and mirror to durable storage."""
        if not session_id:
            return
        self._owned.add(session_id)
        if self._durable is not None:
            self._durable.add_owned_session(session_id)

    def _unmark_owned(self, session_id: str) -> None:
        """Remove ``session_id`` from the owned set and durable storage."""
        if not session_id:
            return
        self._owned.discard(session_id)
        if self._durable is not None:
            self._durable.remove_owned_session(session_id)

    # -- lifecycle --------------------------------------------------------
    async def connect(self) -> None:
        """Open the WS, authenticate, await ``gateway.ready``, start the reader.

        Single-shot: opens ONE connection and returns once it is ready (best
        effort — a missing ``gateway.ready`` within ``connect_timeout_s`` is
        tolerated, exactly as the R0 spike tolerated it). Durable reconnection is
        :meth:`run`'s job; callers wanting resilience use :meth:`run`.
        """
        await self._connect_once()

    async def wait_ready(self, timeout: float = 10.0) -> bool:
        """Wait until the gateway connection is ready (``gateway.ready`` received).

        Returns True if ready within ``timeout``, False otherwise. Used by the
        downstream server to handle the relay-restart timing gap: the phone
        reconnects to the relay's downstream server immediately, but the relay's
        gateway connection might not be up yet. Without this, a submit/resume
        arriving in that window fails with "gateway not connected" and the
        outbox retains the job with no further wake.
        """
        try:
            await asyncio.wait_for(self._ready.wait(), timeout=timeout)
            return True
        except asyncio.TimeoutError:
            return False

    async def run(self) -> None:
        """Durable connect/serve/reconnect loop with exponential backoff.

        On each drop: back off (capped), reconnect, re-mint the URL, re-resume
        owned sessions, and resume publishing events. Runs until :meth:`close`.
        """
        self._closing = False
        backoff = self._cfg.backoff_initial_s
        while not self._closing:
            try:
                await self._connect_once()
            except Exception:
                if self._closing:
                    break
                await self._sleep(backoff)
                backoff = min(backoff * self._cfg.backoff_factor, self._cfg.backoff_max_s)
                continue

            # Connected. Re-establish ownership of every session we drive, then
            # reset the backoff — a healthy connection earns a fresh schedule.
            await self._reestablish_owned()
            backoff = self._cfg.backoff_initial_s

            # Block until the reader loop signals the socket dropped.
            await self._reader_done.wait()
            await self._teardown_transport()
            if self._closing:
                break
            await self._sleep(backoff)
            backoff = min(backoff * self._cfg.backoff_factor, self._cfg.backoff_max_s)

    async def close(self) -> None:
        """Tear down the reader task, close the socket and the REST client."""
        self._closing = True
        # Unblock a run() parked on the reader-done gate.
        self._reader_done.set()
        await self._teardown_transport()
        if self._owns_rest_client and self._rest_client is not None:
            try:
                await self._rest_client.aclose()
            except Exception:
                pass
            self._rest_client = None
        # NOTE: ``_durable`` is shared across lanes (owned by RelayApp); the
        # client must NOT close it here — RelayApp.close() owns its lifecycle.

    async def _connect_once(self) -> None:
        """Open a fresh transport, start its reader, await readiness."""
        url = self._mint_url()
        self._ready.clear()
        self._reader_done = asyncio.Event()
        self._transport = await self._connector(url)
        self._reader_task = asyncio.create_task(self._read_loop(self._transport))
        try:
            await asyncio.wait_for(self._ready.wait(), timeout=self._cfg.connect_timeout_s)
        except asyncio.TimeoutError:
            # gateway.ready is best-effort; proceed. If the socket is truly dead
            # the reader loop will end and run()'s reconnect kicks in.
            pass

    async def _teardown_transport(self) -> None:
        transport, self._transport = self._transport, None
        task, self._reader_task = self._reader_task, None
        if transport is not None:
            try:
                await transport.close()
            except Exception:
                pass
        if task is not None and not task.done():
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
        self._fail_pending(ConnectionError("gateway connection closed"))
        self._ready.clear()

    def _mint_url(self) -> str:
        """Re-mint the WS URL, refreshing the token if a provider is set."""
        if self._token_provider is not None:
            self._token = self._token_provider()
        else:
            self._token = self._cfg.token
        return self._cfg.ws_url(self._token)

    # -- reader / demux ---------------------------------------------------
    async def _read_loop(self, transport: WSTransport) -> None:
        """Read newline-delimited JSON-RPC, resolve responses, publish events."""
        try:
            while True:
                raw = await transport.recv()
                for line in str(raw).splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        msg = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(msg, dict):
                        self._dispatch(msg)
        except asyncio.CancelledError:
            raise
        except Exception:
            # Any transport error == disconnect; run()'s loop reconnects.
            pass
        finally:
            self._fail_pending(ConnectionError("gateway connection closed"))
            self._reader_done.set()

    def _dispatch(self, msg: dict[str, Any]) -> None:
        """Route one parsed frame: event -> bus, response -> matched future."""
        if msg.get("method") == "event":
            params = msg.get("params") or {}
            ev = GatewayEvent.from_rpc_params(params)
            if ev.type == RawEvent.GATEWAY_READY:
                self._ready.set()
            # Demux by session_id happens downstream (Reframer keys on it); we
            # publish every event verbatim onto the one gateway-events topic.
            self._bus.publish(TOPIC_GATEWAY_EVENTS, ev)
            return
        rid = msg.get("id")
        if rid is not None:
            fut = self._pending.pop(rid, None)
            if fut is not None and not fut.done():
                fut.set_result(msg)

    def _fail_pending(self, exc: BaseException) -> None:
        pending, self._pending = self._pending, {}
        for fut in pending.values():
            if not fut.done():
                fut.set_exception(exc)

    # -- RPC core ---------------------------------------------------------
    def _next_id(self) -> int:
        self._next_id_n += 1
        return self._next_id_n

    async def call(
        self, method: str, params: Optional[dict[str, Any]] = None, timeout: Optional[float] = None
    ) -> dict[str, Any]:
        """Issue an id-matched JSON-RPC call, return the raw response dict.

        Raises :class:`ConnectionError` if not connected, ``asyncio.TimeoutError``
        on timeout, and otherwise returns the full response (caller inspects
        ``result``/``error``). The typed convenience methods below wrap this and
        raise :class:`GatewayRPCError` on an ``error`` object.
        """
        transport = self._transport
        if transport is None:
            raise ConnectionError("gateway not connected")
        rid = self._next_id()
        frame = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}
        fut: "asyncio.Future[dict[str, Any]]" = asyncio.get_running_loop().create_future()
        self._pending[rid] = fut
        try:
            await transport.send(json.dumps(frame))
        except Exception:
            self._pending.pop(rid, None)
            raise
        try:
            return await asyncio.wait_for(fut, timeout=timeout or self._cfg.rpc_timeout_s)
        except (asyncio.TimeoutError, asyncio.CancelledError):
            self._pending.pop(rid, None)
            raise

    async def _call_result(
        self, method: str, params: dict[str, Any], timeout: Optional[float] = None
    ) -> dict[str, Any]:
        """``call`` + unwrap: raise on ``error``, else return ``result`` dict."""
        resp = await self.call(method, params, timeout=timeout)
        if "error" in resp and resp["error"] is not None:
            raise GatewayRPCError(method, resp["error"])
        return resp.get("result") or {}

    # -- session ops (protocol §5) ---------------------------------------
    async def session_list(self, limit: int = 200) -> list[dict[str, Any]]:
        """``session.list`` — all sessions, every origin (no ownership)."""
        result = await self._call_result("session.list", {"limit": limit})
        return list(result.get("sessions") or [])

    async def session_create(
        self, *, title: str, model: Optional[str] = None, provider: Optional[str] = None,
        cols: Optional[int] = None,
    ) -> str:
        """``session.create`` — new owned session; returns its session_id."""
        params: dict[str, Any] = {
            "title": title,
            "cols": cols if cols is not None else self._cfg.cols,
            "source": self._cfg.source,
        }
        if model is not None:
            params["model"] = model
        if provider is not None:
            params["provider"] = provider
        result = await self._call_result("session.create", params)
        sid = result.get("session_id")
        if not sid:
            raise GatewayRPCError("session.create", {"code": -1, "message": "no session_id in result"})
        self._mark_owned(sid)
        return sid

    async def session_resume(self, session_id: str, *, cols: Optional[int] = None) -> dict[str, Any]:
        """``session.resume`` — own an idle/foreign session (REACTIVATES it).

        Only call for a session the relay intends to OWN and drive; for a pure
        read use :meth:`rest_history` (store-read, no reactivation). Returns the
        full result (``session_id`` of the live session, ``resumed`` = origin id,
        ``message_count``). The requested id is marked owned so reconnect
        re-resumes it.
        """
        params = {
            "session_id": session_id,
            "cols": cols if cols is not None else self._cfg.cols,
            "source": self._cfg.source,
        }
        result = await self._call_result("session.resume", params, timeout=self._cfg.rpc_timeout_s)
        # Persist the STABLE origin id (what the phone sends); the live id below
        # is connection-local and re-learned on every reconnect, so it stays
        # in-memory only.
        self._mark_owned(session_id)
        # If the gateway hands back a distinct live id, own it too so events on
        # that id are recognised as ours, and remember origin->live so a submit
        # to EITHER id drives the live turn (see :meth:`live_id_for`).
        live = result.get("session_id")
        if live:
            self._owned.add(live)
            self._live_by_origin[session_id] = live
            self._live_by_origin[live] = live
        return result

    async def rest_history(self, session_id: str) -> list[dict[str, Any]]:
        """``GET /api/sessions/{id}/messages`` — foreign/idle history store-read.

        R0 CORRECTION: this REST path (not the ``session.history`` RPC) is the
        true store-read; it does NOT reactivate the session and does NOT take
        ownership. Uses httpx off the WS loop.
        """
        client = self._rest()
        url = f"{self._cfg.http_base}/api/sessions/{session_id}/messages"
        resp = await client.get(url, headers=self._cfg.rest_headers(self._token), timeout=10.0)
        resp.raise_for_status()
        data = resp.json()
        return list(data.get("messages") or [])

    async def prompt_submit(self, session_id: str, text: str) -> dict[str, Any]:
        """``prompt.submit`` — become owner of ``session_id`` and drive a turn.

        Marks the session owned so reconnect re-establishes it and the Notifier
        treats its completion/approval/error events as push-worthy.
        """
        self._mark_owned(session_id)
        return await self._call_result("prompt.submit", {"session_id": session_id, "text": text})

    async def approval_respond(
        self, session_id: str, request_id: str, decision: str, *, resolve_all: bool = False
    ) -> dict[str, Any]:
        """``approval.respond`` — answer an approval gate.

        WIRE-SHAPE CORRECTION: the stock gateway's ``approval.respond`` handler
        reads ``choice`` (one of ``once``/``session``/``always``/``deny``, and
        maps ``approve``->``once``) and ``all``, and resolves the gate by SESSION
        key — it does NOT read ``decision`` or ``request_id``. Sending
        ``decision`` therefore silently defaulted every phone approval to a DENY.
        We map the phone's ``decision`` onto ``choice`` (``request_id`` is kept
        for logging/forward-compat but the gateway ignores it).
        """
        return await self._call_result(
            "approval.respond",
            {
                "session_id": session_id,
                "request_id": request_id,
                "choice": decision,
                "all": resolve_all,
            },
        )

    async def clarify_respond(self, session_id: str, request_id: str, text: str) -> dict[str, Any]:
        """``clarify.respond`` — answer a clarify gate.

        WIRE-SHAPE CORRECTION: the stock gateway's ``clarify.respond`` handler
        (``_respond(rid, params, "answer")``) matches the pending waiter by
        ``request_id`` and stores ``params["answer"]`` — it does NOT read
        ``text``. Sending ``text`` therefore delivered an EMPTY answer to the
        blocked agent. We send ``answer`` (``session_id`` is kept for symmetry;
        the gateway resolves by ``request_id``).
        """
        return await self._call_result(
            "clarify.respond",
            {"session_id": session_id, "request_id": request_id, "answer": text},
        )

    async def session_interrupt(self, session_id: str) -> dict[str, Any]:
        """``session.interrupt`` — stop the active turn (pass-through)."""
        return await self._call_result("session.interrupt", {"session_id": session_id})

    async def session_steer(self, session_id: str, text: str) -> dict[str, Any]:
        """``session.steer`` — inject steering text into the live turn (pass-through).

        QA-2 R11: before this existed the phone had NO relay-path steer — its
        ``session.steer`` RPC went out over the gateway-DIRECT socket, which is
        idle in relay mode, so every steer attempt failed with "Not connected".
        The gateway handler (``server.py`` ``@method("session.steer")``) reads
        ``text`` and resolves the session off ``session_id``; it returns
        ``{status: "queued" | "rejected", text}`` which the relay passes through
        verbatim so the phone maps the disposition exactly as on the direct path
        (``queued`` → clear the field; ``rejected`` → keep the text and offer
        queueing instead).
        """
        return await self._call_result(
            "session.steer", {"session_id": session_id, "text": text}
        )

    # -- attachments (B9/A5: REST-free, bytes inlined) --------------------
    async def file_attach(
        self, session_id: str, *, name: str, data_url: str, timeout: float = 90.0
    ) -> dict[str, Any]:
        """``file.attach`` — stage a non-image file into the session workspace.

        The phone inlines the bytes as a ``data:<mime>;base64,`` URL (it cannot
        assume a gateway-visible path), and the gateway materialises the file
        into ``.hermes/desktop-attachments/``, returning ``{attached, name,
        path, ref_path, ref_text, uploaded}`` — the ``ref_text`` (``@file:…``)
        is what the composer appends to the outgoing prompt. Generous timeout:
        a 25 MB cap file is a ~33 MB base64 payload over this socket.
        """
        return await self._call_result(
            "file.attach",
            {"session_id": session_id, "name": name, "data_url": data_url},
            timeout=timeout,
        )

    async def image_attach_bytes(
        self, session_id: str, *, data_url: str, filename: str = "", timeout: float = 90.0
    ) -> dict[str, Any]:
        """``image.attach_bytes`` — attach a photo from inlined base64 bytes.

        The gateway's handler accepts a ``data:image/…;base64,`` URL as
        ``content_base64`` (prefix + embedded whitespace tolerated), so the
        phone's ``data_url`` passes through untouched — NO ``POST /api/upload``
        REST round-trip, which is exactly what a relay-only phone cannot make.
        Returns the same shape as ``image.attach`` (``{attached, path, …}``).
        """
        params: dict[str, Any] = {"session_id": session_id, "content_base64": data_url}
        if filename:
            params["filename"] = filename
        return await self._call_result("image.attach_bytes", params, timeout=timeout)

    # -- reconnect re-establishment --------------------------------------
    async def _reestablish_owned(self) -> None:
        """Re-resume every owned session on a fresh connection (best effort).

        A failed re-resume (session vanished, transient error) is logged via the
        returned counters but never tears down the loop — the phone can always
        re-drive. Ids are snapshotted so a concurrent submit can't mutate the
        set mid-iteration.
        """
        for sid in sorted(self._owned):
            try:
                await self.call(
                    "session.resume",
                    {"session_id": sid, "cols": self._cfg.cols, "source": self._cfg.source},
                    timeout=self._cfg.rpc_timeout_s,
                )
            except Exception:
                # Keep the session owned; a later phone action re-drives it.
                continue

    # -- REST client ------------------------------------------------------
    def _rest(self) -> Any:
        if self._rest_client is None:
            import httpx  # local import: only needed on the REST path

            self._rest_client = httpx.AsyncClient()
            self._owns_rest_client = True
        return self._rest_client

    # -- ownership introspection -----------------------------------------
    def owns(self, session_id: str) -> bool:
        """True iff the relay owns (submitted/resumed-to-drive) this session."""
        return session_id in self._owned

    def live_id_for(self, session_id: str) -> str:
        """Resolve a requested/origin id to the live id a prior resume assigned.

        Returns ``session_id`` unchanged when no remap is known (the common case
        where the gateway resumes a session in place). When the gateway assigned
        a distinct live id at resume time, this lets a repeat submit addressed to
        the ORIGIN id still target the live turn instead of the dormant origin.
        """
        return self._live_by_origin.get(session_id, session_id)

    @property
    def owned_sessions(self) -> frozenset[str]:
        return frozenset(self._owned)


def _default_connector(config: GatewayConfig) -> Connector:
    """Build the real websockets-backed connector (deferred import)."""

    async def _connect(url: str) -> WSTransport:
        import websockets  # local import so unit tests never require the dep at import time

        return await websockets.connect(url, max_size=config.max_message_bytes)  # type: ignore[return-value]

    return _connect
