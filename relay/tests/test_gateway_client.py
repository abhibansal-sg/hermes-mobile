"""Lane 1 — GatewayClient unit tests (mock WS, no live gateway, no network).

Every test drives the client through an injected in-memory transport / REST
client, so the whole suite is hermetic. Coverage per the lane brief:

* request/response matching (id-matched, out-of-order, timeout, error unwrap);
* inbound event demux by session_id onto ``TOPIC_GATEWAY_EVENTS``;
* reconnect + re-resume of owned sessions after a drop;
* foreign history via REST (store-read, no WS, no ownership).
"""

from __future__ import annotations

import asyncio
import json

import pytest

from hermes_relay.bus import EventBus, TOPIC_GATEWAY_EVENTS
from hermes_relay.gateway_client import (
    GatewayClient,
    GatewayConfig,
    GatewayRPCError,
)
from hermes_relay.types import GatewayEvent, RawEvent


# ---------------------------------------------------------------------------
# In-memory transport + connectors (the mock WS)
# ---------------------------------------------------------------------------
_CLOSE = object()


class FakeTransport:
    """A scriptable stand-in for a websockets connection.

    ``send`` records the parsed frame and, if a ``responder`` is set, enqueues
    the response it returns. ``recv`` yields queued JSON lines until ``close``.
    """

    def __init__(self, *, ready=True, responder=None):
        self.sent: list[dict] = []
        self.inbox: "asyncio.Queue" = asyncio.Queue()
        self.closed = False
        self._responder = responder
        if ready:
            self.push_event(RawEvent.GATEWAY_READY, None, {})

    # -- transport surface --
    async def send(self, data: str) -> None:
        frame = json.loads(data)
        self.sent.append(frame)
        if self._responder is not None:
            resp = self._responder(frame)
            if resp is not None:
                self.push(resp)

    async def recv(self):
        item = await self.inbox.get()
        if item is _CLOSE:
            raise ConnectionError("transport closed")
        return item

    async def close(self) -> None:
        if not self.closed:
            self.closed = True
            self.inbox.put_nowait(_CLOSE)

    # -- test helpers --
    def push(self, obj) -> None:
        self.inbox.put_nowait(json.dumps(obj))

    def push_event(self, etype, session_id, payload) -> None:
        self.push({
            "jsonrpc": "2.0",
            "method": "event",
            "params": {"type": etype, "session_id": session_id, "payload": payload},
        })

    def methods_sent(self) -> list[str]:
        return [f.get("method") for f in self.sent]


def echo_responder(frame: dict) -> dict:
    """A minimal gateway: answers each RPC with a plausible result."""
    method = frame["method"]
    params = frame.get("params") or {}
    if method == "session.list":
        result = {"sessions": [
            {"id": "clisess01", "source": "cli"},
            {"id": "tgsess001", "source": "telegram"},
        ]}
    elif method == "session.create":
        result = {"session_id": "owned-new"}
    elif method == "session.resume":
        result = {"session_id": params.get("session_id"), "resumed": params.get("session_id"),
                  "message_count": 2}
    elif method == "prompt.submit":
        result = {"accepted": True}
    else:
        result = {"ok": True}
    return {"jsonrpc": "2.0", "id": frame["id"], "result": result}


def one_shot_connector(transport: FakeTransport):
    async def _connect(url: str) -> FakeTransport:
        return transport
    return _connect


class ScriptedConnector:
    """Hands out a scripted list of transports, one per (re)connect."""

    def __init__(self, transports: list[FakeTransport]):
        self._queue = list(transports)
        self.urls: list[str] = []
        self.made: list[FakeTransport] = []

    async def __call__(self, url: str) -> FakeTransport:
        self.urls.append(url)
        if not self._queue:
            # Park forever rather than crash the reconnect loop in a test.
            await asyncio.Event().wait()
        t = self._queue.pop(0)
        self.made.append(t)
        return t


async def _noop_sleep(_secs: float) -> None:
    return None


async def wait_until(pred, timeout=1.0):
    deadline = asyncio.get_event_loop().time() + timeout
    while asyncio.get_event_loop().time() < deadline:
        if pred():
            return True
        await asyncio.sleep(0)
    return pred()


def make_client(transport=None, *, responder=None, connector=None, rest_client=None,
                sleep=_noop_sleep, token="tok", token_provider=None):
    bus = EventBus()
    if connector is None:
        transport = transport or FakeTransport(responder=responder)
        connector = one_shot_connector(transport)
    cfg = GatewayConfig(token=token, port=9126, connect_timeout_s=0.5,
                        backoff_initial_s=0.0, backoff_max_s=0.0)
    client = GatewayClient(cfg, bus, connector=connector, rest_client=rest_client,
                           sleep=sleep, token_provider=token_provider)
    return client, bus


# ---------------------------------------------------------------------------
# request / response matching
# ---------------------------------------------------------------------------
async def test_call_returns_matched_result():
    client, _ = make_client(responder=echo_responder)
    await client.connect()
    sessions = await client.session_list()
    assert {s["id"] for s in sessions} == {"clisess01", "tgsess001"}
    await client.close()


async def test_out_of_order_responses_match_by_id():
    transport = FakeTransport()  # no auto-responder; we control replies
    client, _ = make_client(transport)
    await client.connect()

    ta = asyncio.create_task(client.call("m.a"))
    tb = asyncio.create_task(client.call("m.b"))
    await wait_until(lambda: len(transport.sent) >= 2)
    id_a = transport.sent[0]["id"]
    id_b = transport.sent[1]["id"]
    assert id_a != id_b
    # respond in REVERSE order
    transport.push({"jsonrpc": "2.0", "id": id_b, "result": {"which": "b"}})
    transport.push({"jsonrpc": "2.0", "id": id_a, "result": {"which": "a"}})
    ra = await ta
    rb = await tb
    assert ra["result"]["which"] == "a"
    assert rb["result"]["which"] == "b"
    await client.close()


async def test_call_timeout_cleans_pending():
    transport = FakeTransport()
    client, _ = make_client(transport)
    await client.connect()
    with pytest.raises(asyncio.TimeoutError):
        await client.call("never.answered", timeout=0.02)
    assert client._pending == {}
    await client.close()


async def test_rpc_error_is_raised_by_typed_method():
    def err_responder(frame):
        return {"jsonrpc": "2.0", "id": frame["id"],
                "error": {"code": 4001, "message": "session not found"}}

    client, _ = make_client(responder=err_responder)
    await client.connect()
    with pytest.raises(GatewayRPCError) as ei:
        await client.session_interrupt("nope")
    assert ei.value.code == 4001
    await client.close()


async def test_call_without_connection_raises():
    client, _ = make_client()
    with pytest.raises(ConnectionError):
        await client.call("session.list")


# ---------------------------------------------------------------------------
# event demux by session_id
# ---------------------------------------------------------------------------
async def test_events_demuxed_onto_bus_by_session_id():
    transport = FakeTransport()
    client, bus = make_client(transport)
    sub = bus.subscribe(TOPIC_GATEWAY_EVENTS)
    await client.connect()  # consumes the pre-loaded gateway.ready

    transport.push_event(RawEvent.MESSAGE_DELTA, "sidA", {"text": "hello"})
    transport.push_event(RawEvent.TOOL_START, "sidB", {"name": "bash"})
    transport.push_event(RawEvent.MESSAGE_COMPLETE, "sidA", {"usage": {"tokens": 3}})

    got: list[GatewayEvent] = []
    await wait_until(lambda: _drain(sub, got) >= 4)  # ready + 3

    ready = [e for e in got if e.type == RawEvent.GATEWAY_READY]
    a = [e for e in got if e.session_id == "sidA"]
    b = [e for e in got if e.session_id == "sidB"]
    assert len(ready) == 1
    assert [e.type for e in a] == [RawEvent.MESSAGE_DELTA, RawEvent.MESSAGE_COMPLETE]
    assert a[0].payload["text"] == "hello"
    assert b[0].type == RawEvent.TOOL_START and b[0].payload["name"] == "bash"
    assert client._ready.is_set()
    await client.close()


def _drain(sub, out: list) -> int:
    while True:
        try:
            out.append(sub._q.get_nowait())
        except asyncio.QueueEmpty:
            break
    return len(out)


# ---------------------------------------------------------------------------
# ownership tracking
# ---------------------------------------------------------------------------
async def test_create_resume_submit_take_ownership_open_does_not():
    client, _ = make_client(responder=echo_responder)
    await client.connect()

    sid = await client.session_create(title="new chat", model="glm-4.6", provider="zai")
    assert sid == "owned-new" and client.owns("owned-new")

    await client.session_resume("clisess01")
    assert client.owns("clisess01")

    await client.prompt_submit("clisess01", "hi")
    assert client.owns("clisess01")

    # session.list is a pure read: no ownership.
    await client.session_list()
    assert client.owned_sessions == frozenset({"owned-new", "clisess01"})
    await client.close()


# ---------------------------------------------------------------------------
# reconnect + re-resume of owned sessions
# ---------------------------------------------------------------------------
async def test_reconnect_reresumes_owned_sessions():
    t1 = FakeTransport(responder=echo_responder)
    t2 = FakeTransport(responder=echo_responder)
    connector = ScriptedConnector([t1, t2])
    bus = EventBus()
    cfg = GatewayConfig(token="tok", port=9126, connect_timeout_s=0.5,
                        backoff_initial_s=0.0, backoff_max_s=0.0)
    client = GatewayClient(cfg, bus, connector=connector, sleep=_noop_sleep)

    run_task = asyncio.create_task(client.run())
    # first connection is live + ready
    await wait_until(lambda: client._transport is t1 and client._ready.is_set())

    # own an idle foreign session over connection #1
    await client.session_resume("clisess01")
    assert client.owns("clisess01")

    # drop connection #1 -> reconnect loop should move to t2 and re-resume
    await t1.close()
    await wait_until(lambda: client._transport is t2 and client._ready.is_set())
    await wait_until(lambda: any(
        f.get("method") == "session.resume"
        and (f.get("params") or {}).get("session_id") == "clisess01"
        for f in t2.sent
    ))

    assert len(connector.made) == 2  # exactly one reconnect
    await client.close()
    run_task.cancel()
    try:
        await run_task
    except asyncio.CancelledError:
        pass


async def test_url_reminted_with_rotating_token_on_reconnect():
    t1 = FakeTransport()
    t2 = FakeTransport()
    connector = ScriptedConnector([t1, t2])
    tokens = iter(["tok-1", "tok-2"])
    bus = EventBus()
    cfg = GatewayConfig(token="unused", port=9126, connect_timeout_s=0.5,
                        backoff_initial_s=0.0, backoff_max_s=0.0)
    client = GatewayClient(cfg, bus, connector=connector, sleep=_noop_sleep,
                           token_provider=lambda: next(tokens))

    run_task = asyncio.create_task(client.run())
    await wait_until(lambda: len(connector.urls) >= 1 and client._ready.is_set())
    await t1.close()
    await wait_until(lambda: len(connector.urls) >= 2)

    assert "token=tok-1" in connector.urls[0]
    assert "token=tok-2" in connector.urls[1]
    await client.close()
    run_task.cancel()
    try:
        await run_task
    except asyncio.CancelledError:
        pass


async def test_pending_calls_fail_on_disconnect():
    transport = FakeTransport()
    client, _ = make_client(transport)
    await client.connect()
    pending = asyncio.create_task(client.call("slow.rpc", timeout=5))
    await wait_until(lambda: len(transport.sent) >= 1)
    await transport.close()  # drop while the call is in flight
    with pytest.raises(ConnectionError):
        await pending


# ---------------------------------------------------------------------------
# foreign history via REST (store-read, no WS, no ownership)
# ---------------------------------------------------------------------------
class FakeResponse:
    def __init__(self, payload):
        self._payload = payload
        self.status_code = 200

    def raise_for_status(self):
        return None

    def json(self):
        return self._payload


class FakeRestClient:
    def __init__(self, payload):
        self._payload = payload
        self.calls: list[dict] = []

    async def get(self, url, headers=None, timeout=None):
        self.calls.append({"url": url, "headers": headers or {}, "timeout": timeout})
        return FakeResponse(self._payload)

    async def aclose(self):
        return None


async def test_foreign_history_via_rest_no_ws_no_ownership():
    rest = FakeRestClient({"messages": [
        {"role": "user", "content": "weather in Kyoto?"},
        {"role": "assistant", "content": "Rainy."},
    ]})
    # A transport that would RAISE if any WS RPC were attempted.
    transport = FakeTransport()
    client, _ = make_client(transport, rest_client=rest, token="secret-tok")
    await client.connect()

    msgs = await client.rest_history("tgsess001")

    assert len(msgs) == 2 and any("Kyoto" in m["content"] for m in msgs)
    # REST path was used, targeting the store-read endpoint with the auth header.
    assert len(rest.calls) == 1
    assert rest.calls[0]["url"].endswith("/api/sessions/tgsess001/messages")
    assert rest.calls[0]["headers"].get("X-Hermes-Session-Token") == "secret-tok"
    # store-read never touches the WS and never takes ownership.
    assert transport.methods_sent() == []
    assert not client.owns("tgsess001")
    await client.close()
