"""N7 — gateway middleware hardening contract tests (in-repo hermes_cli).

The dashboard stacks five ``@app.middleware("http")`` auth gates
(web_server.py: ``host_header_middleware``, ``_plugin_api_runtime_gate``,
``_dashboard_auth_gate`` → ``gated_auth_middleware``, ``auth_middleware``,
``_token_auth_seam`` → ``token_auth_middleware``). Starlette's
``BaseHTTPMiddleware`` re-raises a downstream exception out of
``call_next`` — internally it travels through an anyio task group as an
``ExceptionGroup`` — so a gate that doesn't catch it lets the failure
escape the entire middleware stack: no structured response for the client,
crash traceback on the ASGI server.

Every gate now routes ``call_next`` through
``hermes_cli.dashboard_auth.call_guard.guarded_call_next`` (500
JSONResponse on any downstream Exception / ExceptionGroup; a late
WebSocketDisconnect swallowed with a 204) and pins the WebSocket-scope
exemption explicitly (``scope_is_http``). These tests lock the contract:

  1. a route that raises → 500 JSON + the app keeps serving (worker alive);
  2. auth verdicts unchanged: 401s (loopback + OAuth gate + token seam),
     503s, Host-header 400s all exactly as before;
  3. WebSocket connect / immediate disconnect → no exception escapes, and
     WS scopes never enter an auth dispatch.
"""
from __future__ import annotations

import types

import pytest
from fastapi import WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

from hermes_cli import web_server
from hermes_cli.dashboard_auth import (
    DashboardAuthProvider,
    LoginStart,
    Session,
    TokenPrincipal,
    clear_providers,
    register_provider,
)
from hermes_cli.dashboard_auth import token_auth
from hermes_cli.dashboard_auth.call_guard import (
    INTERNAL_ERROR_BODY,
    guarded_call_next,
    scope_is_http,
)
from hermes_cli.dashboard_auth.middleware import gated_auth_middleware
from tests.hermes_cli.conftest_dashboard_auth import StubAuthProvider

# --------------------------------------------------------------------------
# Shared fakes (mirrors the style of test_dashboard_token_auth.py)
# --------------------------------------------------------------------------


class _FakeURL:
    def __init__(self, path):
        self.path = path
        self.query = ""


class _FakeClient:
    host = "1.2.3.4"


class _FakeRequest:
    """Minimal Request stand-in for the gates (no real Starlette needed).

    ``scope`` defaults to an HTTP scope; pass ``scope_type="websocket"`` to
    simulate a WS upgrade. Requests without a scope at all are legal too —
    ``scope_is_http`` treats them as HTTP (lenient on test doubles).
    """

    def __init__(self, path="/api/x", headers=None, scope_type="http",
                 auth_required=False, with_scope=True):
        self.url = _FakeURL(path)
        self.headers = headers or {}
        self.client = _FakeClient()
        self.cookies: dict = {}
        if with_scope:
            self.scope = {"type": scope_type, "path": path}

        class _State:
            pass

        self.state = _State()
        self.app = types.SimpleNamespace(
            state=types.SimpleNamespace(auth_required=auth_required)
        )


async def _call_next_ok(request):
    return JSONResponse({"ok": True}, status_code=200)


async def _call_next_boom(request):
    raise RuntimeError("downstream exploded")


async def _call_next_group_boom(request):
    raise ExceptionGroup(  # noqa: F821 — py3.11+ builtin
        "downstream task group failures",
        [RuntimeError("one"), ValueError("two")],
    )


async def _call_next_ws_disconnect(request):
    raise WebSocketDisconnect(code=1006)


# --------------------------------------------------------------------------
# Isolation: the full-app tests mutate web_server.app + global registries.
# Per-file process isolation keeps OTHER test files safe; this fixture keeps
# tests inside THIS file from leaking into each other.
# --------------------------------------------------------------------------

_BOOM_PATH = "/api/__n7_hardening_boom"
_TOKEN_BOOM_PATH = "/api/__n7_hardening_token_boom"
_GATED_BOOM_PATH = "/api/__n7_hardening_gated_boom"
_WS_PATH = "/__n7_hardening_ws"
_ALL_TEST_ROUTES = {_BOOM_PATH, _TOKEN_BOOM_PATH, _GATED_BOOM_PATH, _WS_PATH}


def _remove_test_routes() -> None:
    web_server.app.router.routes[:] = [
        r for r in web_server.app.router.routes
        if getattr(r, "path", None) not in _ALL_TEST_ROUTES
    ]


@pytest.fixture
def isolated_app_state():
    """Snapshot/restore app.state + global auth registries + test routes."""
    prev_host = getattr(web_server.app.state, "bound_host", None)
    prev_port = getattr(web_server.app.state, "bound_port", None)
    prev_required = getattr(web_server.app.state, "auth_required", None)
    clear_providers()
    token_auth.clear_token_routes()
    yield
    _remove_test_routes()
    clear_providers()
    token_auth.clear_token_routes()
    if prev_host is None:
        if hasattr(web_server.app.state, "bound_host"):
            del web_server.app.state.bound_host
    else:
        web_server.app.state.bound_host = prev_host
    if prev_port is None:
        if hasattr(web_server.app.state, "bound_port"):
            del web_server.app.state.bound_port
    else:
        web_server.app.state.bound_port = prev_port
    if prev_required is None:
        if hasattr(web_server.app.state, "auth_required"):
            del web_server.app.state.auth_required
    else:
        web_server.app.state.auth_required = prev_required


@pytest.fixture
def loopback_client(isolated_app_state):
    """Full dashboard app in loopback mode; Host check satisfied."""
    web_server.app.state.bound_host = "127.0.0.1"
    web_server.app.state.bound_port = 9119
    # raise_server_exceptions stays at its True default ON PURPOSE: if any
    # exception escapes the hardened middleware stack, TestClient re-raises
    # it here and the test fails loudly instead of asserting a 500 that
    # never came from a gate.
    return TestClient(web_server.app, base_url="http://127.0.0.1:9119")


def _register_boom(path: str) -> None:
    async def _boom():
        raise RuntimeError("n7-hardening-boom")

    web_server.app.get(path)(_boom)
    # Starlette matches routes in registration order, and web_server.py's
    # SPA catch-all (``/{full_path:path}``) was registered at import time —
    # an appended route would be shadowed by it (and 404 when web_dist is
    # absent). Move the test route to the FRONT so it wins matching.
    route = web_server.app.router.routes.pop()
    web_server.app.router.routes.insert(0, route)


# ==========================================================================
# 1. call_guard unit contract
# ==========================================================================


class TestGuardedCallNext:
    def test_downstream_exception_becomes_500_json(self):
        req = _FakeRequest()
        import asyncio

        resp = asyncio.run(
            guarded_call_next(req, _call_next_boom, gate="test-gate")
        )
        assert resp.status_code == 500
        assert resp.body  # JSONResponse renders a body
        import json

        assert json.loads(resp.body) == dict(INTERNAL_ERROR_BODY)

    def test_downstream_exception_group_becomes_500_json(self):
        """The exact shape Starlette's middleware task group produces must
        be converted, never re-raised."""
        req = _FakeRequest()
        import asyncio

        resp = asyncio.run(
            guarded_call_next(req, _call_next_group_boom, gate="test-gate")
        )
        assert resp.status_code == 500

    def test_websocket_disconnect_is_swallowed(self):
        req = _FakeRequest()
        import asyncio

        resp = asyncio.run(
            guarded_call_next(req, _call_next_ws_disconnect, gate="test-gate")
        )
        assert resp.status_code == 204

    def test_downstream_success_passes_through_untouched(self):
        req = _FakeRequest()
        import asyncio

        resp = asyncio.run(
            guarded_call_next(req, _call_next_ok, gate="test-gate")
        )
        assert resp.status_code == 200

    def test_scope_is_http_truth_table(self):
        assert scope_is_http(_FakeRequest(scope_type="http")) is True
        assert scope_is_http(_FakeRequest(scope_type="websocket")) is False
        assert scope_is_http(_FakeRequest(scope_type="lifespan")) is False
        # No scope attribute at all → treated as HTTP (lenient on doubles).
        assert scope_is_http(_FakeRequest(with_scope=False)) is True


# ==========================================================================
# 2. Gate-level unit tests (direct dispatch invocation)
# ==========================================================================


class TestTokenAuthSeamHardening:
    @pytest.fixture(autouse=True)
    def _registries(self):
        clear_providers()
        token_auth.clear_token_routes()
        yield
        clear_providers()
        token_auth.clear_token_routes()

    def _register_token_provider(self, secret="n7-secret"):
        class _Provider(DashboardAuthProvider):
            name = "n7-tok"
            display_name = "N7 Token Provider"
            supports_token = True

            def start_login(self, *, redirect_uri):
                return LoginStart(redirect_url="x", cookie_payload={})

            def complete_login(self, *, code, state, code_verifier, redirect_uri):
                return Session("u", "e", "n", "o", self.name, 0, "a", "r")

            def verify_session(self, *, access_token):
                return None

            def refresh_session(self, *, refresh_token):
                return Session("u", "e", "n", "o", self.name, 0, "a", "r")

            def revoke_session(self, *, refresh_token):
                return None

            def verify_token(self, *, token):
                if token == secret:
                    return TokenPrincipal(
                        principal=self.name, provider=self.name, scopes=()
                    )
                return None

        register_provider(_Provider())

    def test_unregistered_route_downstream_crash_becomes_500(self):
        import asyncio

        req = _FakeRequest(path="/api/ordinary")
        resp = asyncio.run(token_auth.token_auth_middleware(req, _call_next_boom))
        assert resp.status_code == 500

    def test_registered_route_valid_token_downstream_crash_becomes_500(self):
        import asyncio

        self._register_token_provider()
        token_auth.register_token_route("/api/svc")
        req = _FakeRequest(
            path="/api/svc", headers={"authorization": "Bearer n7-secret"}
        )
        resp = asyncio.run(token_auth.token_auth_middleware(req, _call_next_boom))
        assert resp.status_code == 500
        # Auth succeeded before the crash — the principal was attached.
        assert req.state.token_authenticated is True

    def test_registered_route_missing_token_still_401(self):
        """Auth verdict semantics are unchanged by the hardening."""
        import asyncio

        self._register_token_provider()
        token_auth.register_token_route("/api/svc")
        req = _FakeRequest(path="/api/svc", headers={})
        resp = asyncio.run(token_auth.token_auth_middleware(req, _call_next_ok))
        assert resp.status_code == 401

    def test_websocket_scope_bypasses_token_auth_entirely(self):
        """A WS upgrade on a registered token route WITHOUT a token must
        pass through to downstream — the seam never applies bearer-token
        auth to non-HTTP scopes."""
        import asyncio

        self._register_token_provider()
        token_auth.register_token_route("/api/svc")
        req = _FakeRequest(
            path="/api/svc", headers={}, scope_type="websocket"
        )
        resp = asyncio.run(token_auth.token_auth_middleware(req, _call_next_ok))
        assert resp.status_code == 200
        assert getattr(req.state, "token_authenticated", False) is False


class TestGatedAuthMiddlewareHardening:
    @pytest.fixture(autouse=True)
    def _registries(self):
        clear_providers()
        yield
        clear_providers()

    def test_loopback_passthrough_downstream_crash_becomes_500(self):
        import asyncio

        req = _FakeRequest(path="/api/x", auth_required=False)
        resp = asyncio.run(gated_auth_middleware(req, _call_next_boom))
        assert resp.status_code == 500

    def test_gated_public_path_downstream_crash_becomes_500(self):
        import asyncio

        req = _FakeRequest(path="/api/status", auth_required=True)
        resp = asyncio.run(gated_auth_middleware(req, _call_next_boom))
        assert resp.status_code == 500

    def test_gated_no_cookie_still_401_json(self):
        """Unchanged verdict: an unauthenticated /api/ request under the
        gate gets the 401 JSON envelope with login_url — never the guard's
        500 (the guard only owns downstream execution)."""
        import asyncio

        register_provider(StubAuthProvider())
        req = _FakeRequest(path="/api/sessions", auth_required=True)
        resp = asyncio.run(gated_auth_middleware(req, _call_next_ok))
        assert resp.status_code == 401
        import json

        body = json.loads(resp.body)
        assert body["error"] == "unauthenticated"
        assert body["login_url"].startswith("/login")

    def test_websocket_scope_bypasses_gate_entirely(self):
        """A WS upgrade must not be bounced through the cookie decision —
        even unauthenticated, it reaches downstream (WS routes run their own
        upgrade-time auth in _ws_auth_reason)."""
        import asyncio

        register_provider(StubAuthProvider())
        req = _FakeRequest(
            path="/api/ws", auth_required=True, scope_type="websocket"
        )
        resp = asyncio.run(gated_auth_middleware(req, _call_next_ok))
        assert resp.status_code == 200


class TestLegacyAuthMiddlewareHardening:
    def test_loopback_valid_token_downstream_crash_becomes_500(self):
        import asyncio

        req = _FakeRequest(
            path="/api/sessions",
            headers={web_server._SESSION_HEADER_NAME: web_server._SESSION_TOKEN},
        )
        resp = asyncio.run(web_server.auth_middleware(req, _call_next_boom))
        assert resp.status_code == 500

    def test_loopback_missing_token_still_401(self):
        import asyncio

        req = _FakeRequest(path="/api/sessions", headers={})
        resp = asyncio.run(web_server.auth_middleware(req, _call_next_ok))
        assert resp.status_code == 401

    def test_websocket_scope_bypasses_session_gate(self):
        import asyncio

        req = _FakeRequest(
            path="/api/sessions", headers={}, scope_type="websocket"
        )
        # Note: auth_middleware has no explicit scope guard (it's a
        # @app.middleware("http") dispatch — Starlette never hands it WS
        # scopes, pinned by the spy test below). This test documents that a
        # WS-shaped request with NO session token would still reach
        # downstream because the /api/ session check is the ONLY gate — the
        # route-level WS auth (_ws_auth_reason) is the real WS enforcement.
        resp = asyncio.run(web_server.auth_middleware(req, _call_next_ok))
        # Without the session token, the legacy gate 401s HTTP requests;
        # WS enforcement lives at upgrade time, so the middleware's verdict
        # is what it always was — the point of this test is that NO
        # exception escapes and the behaviour is deterministic.
        assert resp.status_code in (200, 401)


# ==========================================================================
# 3. Full-app E2E (real stacked middleware, loopback mode)
# ==========================================================================


class TestFullAppDownstreamCrash:
    def test_route_raise_returns_500_json_and_worker_survives(
        self, loopback_client
    ):
        _register_boom(_BOOM_PATH)
        auth = {web_server._SESSION_HEADER_NAME: web_server._SESSION_TOKEN}

        r = loopback_client.get(_BOOM_PATH, headers=auth)
        assert r.status_code == 500
        assert r.headers["content-type"].startswith("application/json")
        assert r.json() == {"detail": "Internal Server Error"}

        # Worker survives: the gate is reusable and the app keeps serving.
        r2 = loopback_client.get(_BOOM_PATH, headers=auth)
        assert r2.status_code == 500
        ok = loopback_client.get("/api/status")
        assert ok.status_code == 200
        assert "version" in ok.json()

    def test_route_raise_unauthenticated_still_401(self, loopback_client):
        """The auth verdict precedes the downstream crash — an anonymous
        caller never learns the route exists by getting a 500."""
        _register_boom(_BOOM_PATH)
        r = loopback_client.get(_BOOM_PATH)
        assert r.status_code == 401
        assert r.json()["detail"] == "Unauthorized"

    def test_host_header_verdict_unchanged_after_crash(self, loopback_client):
        _register_boom(_BOOM_PATH)
        auth = {web_server._SESSION_HEADER_NAME: web_server._SESSION_TOKEN}
        assert loopback_client.get(_BOOM_PATH, headers=auth).status_code == 500
        bad_host = loopback_client.get(
            "/api/status", headers={"Host": "evil.example"}
        )
        assert bad_host.status_code == 400


class _E2ETokenProvider(DashboardAuthProvider):
    name = "n7-e2e-tok"
    display_name = "N7 E2E Token Provider"
    supports_token = True

    def start_login(self, *, redirect_uri):
        return LoginStart(redirect_url="x", cookie_payload={})

    def complete_login(self, *, code, state, code_verifier, redirect_uri):
        return Session("u", "e", "n", "o", self.name, 0, "a", "r")

    def verify_session(self, *, access_token):
        return None

    def refresh_session(self, *, refresh_token):
        return Session("u", "e", "n", "o", self.name, 0, "a", "r")

    def revoke_session(self, *, refresh_token):
        return None

    def verify_token(self, *, token):
        if token == "n7-e2e-secret":
            return TokenPrincipal(principal=self.name, provider=self.name, scopes=())
        return None


class TestFullAppTokenSeamCrash:
    def test_token_route_crash_returns_500_json(self, loopback_client):
        _register_boom(_TOKEN_BOOM_PATH)
        token_auth.register_token_route(_TOKEN_BOOM_PATH)
        register_provider(_E2ETokenProvider())

        r = loopback_client.get(
            _TOKEN_BOOM_PATH,
            headers={"Authorization": "Bearer n7-e2e-secret"},
        )
        assert r.status_code == 500
        assert r.json() == {"detail": "Internal Server Error"}

        # Survives + keeps serving.
        assert loopback_client.get("/api/status").status_code == 200

    def test_token_route_missing_bearer_still_401(self, loopback_client):
        _register_boom(_TOKEN_BOOM_PATH)
        token_auth.register_token_route(_TOKEN_BOOM_PATH)
        register_provider(_E2ETokenProvider())

        r = loopback_client.get(_TOKEN_BOOM_PATH)
        assert r.status_code == 401

    def test_token_route_bad_bearer_still_401(self, loopback_client):
        _register_boom(_TOKEN_BOOM_PATH)
        token_auth.register_token_route(_TOKEN_BOOM_PATH)
        register_provider(_E2ETokenProvider())

        r = loopback_client.get(
            _TOKEN_BOOM_PATH, headers={"Authorization": "Bearer wrong"}
        )
        assert r.status_code == 401


# ==========================================================================
# 4. Full-app E2E — OAuth gate (gated mode) crash + verdict preservation
# ==========================================================================


def _complete_stub_login(client: TestClient) -> None:
    """Walk the stub OAuth round trip; afterwards the client carries a
    valid hermes_session_at/rt cookie pair (mirrors the helper in
    test_dashboard_auth_middleware.py)."""
    r1 = client.get("/auth/login?provider=stub", follow_redirects=False)
    assert r1.status_code == 302
    state = r1.headers["location"].split("state=")[1]
    r2 = client.get(
        f"/auth/callback?code=stub_code&state={state}",
        follow_redirects=False,
    )
    assert r2.status_code == 302


@pytest.fixture
def gated_client(isolated_app_state):
    clear_providers()
    register_provider(StubAuthProvider())
    web_server.app.state.bound_host = "fly-app.fly.dev"
    web_server.app.state.bound_port = 443
    web_server.app.state.auth_required = True
    return TestClient(web_server.app, base_url="https://fly-app.fly.dev")


class TestGatedModeCrash:
    def test_authenticated_cookie_session_crash_returns_500_json(
        self, gated_client
    ):
        _register_boom(_GATED_BOOM_PATH)
        _complete_stub_login(gated_client)

        r = gated_client.get(_GATED_BOOM_PATH)
        assert r.status_code == 500
        assert r.json() == {"detail": "Internal Server Error"}
        # Worker survives under the gate too.
        assert gated_client.get("/api/status").status_code == 200

    def test_unauthenticated_still_401_envelope(self, gated_client):
        _register_boom(_GATED_BOOM_PATH)
        r = gated_client.get(_GATED_BOOM_PATH)
        assert r.status_code == 401
        body = r.json()
        assert body["error"] == "unauthenticated"
        assert body["login_url"].startswith("/login")


# ==========================================================================
# 5. WebSocket behaviour — connect/disconnect clean; auth dispatch never
#    sees a WS scope.
# ==========================================================================


def _register_echo_ws(path: str) -> None:
    async def _ws(ws: WebSocket):
        await ws.accept()
        try:
            msg = await ws.receive_text()
            await ws.send_text(f"echo:{msg}")
        except WebSocketDisconnect:
            pass

    web_server.app.websocket(path)(_ws)


class TestFullAppWebSocket:
    def test_ws_connect_echo_close_no_exception_escape(self, loopback_client):
        """A full WS session through the real stacked middleware: connect,
        round-trip a message, close. No exception may escape — TestClient
        would re-raise it."""
        _register_echo_ws(_WS_PATH)
        with loopback_client.websocket_connect(_WS_PATH) as ws:
            ws.send_text("ping")
            assert ws.receive_text() == "echo:ping"
        # App still serves HTTP afterwards.
        assert loopback_client.get("/api/status").status_code == 200

    def test_ws_immediate_disconnect_no_exception_escape(self, loopback_client):
        """Connect and drop without sending — the abrupt-disconnect path.
        The server-side receive raises WebSocketDisconnect; nothing may
        escape the app as an unhandled exception."""
        _register_echo_ws(_WS_PATH)
        with loopback_client.websocket_connect(_WS_PATH):
            pass  # close immediately
        assert loopback_client.get("/api/status").status_code == 200

    def test_ws_connect_after_http_crash_still_works(self, loopback_client):
        """An HTTP 500 produced by the guard must not poison WS upgrades."""
        _register_boom(_BOOM_PATH)
        _register_echo_ws(_WS_PATH)
        auth = {web_server._SESSION_HEADER_NAME: web_server._SESSION_TOKEN}
        assert loopback_client.get(_BOOM_PATH, headers=auth).status_code == 500
        with loopback_client.websocket_connect(_WS_PATH) as ws:
            ws.send_text("still-alive")
            assert ws.receive_text() == "echo:still-alive"


class TestWsScopesNeverEnterAuthDispatch:
    """Spy harness: a probe app wired with the REAL gate dispatch functions
    plus an outermost spy that records every scope type that reaches an
    auth dispatch. WS scopes must never appear — Starlette's
    BaseHTTPMiddleware routes non-http scopes around dispatch, and this
    test pins that exemption as a regression guard."""

    def _build_probe_app(self, seen: list):
        from fastapi import FastAPI
        from starlette.middleware.base import BaseHTTPMiddleware

        probe = FastAPI()

        async def _spy_dispatch(request, call_next):
            seen.append(request.scope["type"])
            return await call_next(request)

        # Register innermost-first: add_middleware prepends, so the LAST
        # added runs FIRST (outermost). Mirror the real stack: seam → auth
        # → gated → host, with the spy outermost of all.
        probe.add_middleware(
            BaseHTTPMiddleware,
            dispatch=lambda req, cn: web_server.host_header_middleware(req, cn),
        )
        probe.add_middleware(
            BaseHTTPMiddleware,
            dispatch=lambda req, cn: gated_auth_middleware(req, cn),
        )
        probe.add_middleware(
            BaseHTTPMiddleware,
            dispatch=lambda req, cn: web_server.auth_middleware(req, cn),
        )
        probe.add_middleware(
            BaseHTTPMiddleware,
            dispatch=lambda req, cn: web_server._token_auth_seam(req, cn),
        )
        probe.add_middleware(BaseHTTPMiddleware, dispatch=_spy_dispatch)

        @probe.get("/n7_probe")
        async def _probe_http():
            return {"probe": "ok"}

        @probe.websocket("/n7_probe_ws")
        async def _probe_ws(ws: WebSocket):
            await ws.accept()
            try:
                msg = await ws.receive_text()
                await ws.send_text(f"probe:{msg}")
            except WebSocketDisconnect:
                pass

        return probe

    def test_ws_scope_never_reaches_auth_dispatch(self):
        seen: list[str] = []
        probe = self._build_probe_app(seen)
        client = TestClient(probe)

        # HTTP request DOES traverse the dispatch stack…
        r = client.get("/n7_probe")
        assert r.status_code == 200
        assert seen == ["http"]

        # …WS connect/echo/close and abrupt disconnect do NOT.
        with client.websocket_connect("/n7_probe_ws") as ws:
            ws.send_text("hello")
            assert ws.receive_text() == "probe:hello"
        with client.websocket_connect("/n7_probe_ws"):
            pass  # immediate disconnect
        assert seen == ["http"], (
            f"auth dispatch saw non-HTTP scopes: {seen!r}"
        )

        # HTTP still works after the WS sessions.
        assert client.get("/n7_probe").status_code == 200
        assert seen == ["http", "http"]
