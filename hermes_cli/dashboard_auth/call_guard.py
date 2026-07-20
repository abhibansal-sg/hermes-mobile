"""Downstream-exception guard for the dashboard's stacked HTTP auth gates.

Starlette's ``BaseHTTPMiddleware`` (the machinery behind
``@app.middleware("http")``) awaits each gate's ``dispatch(request,
call_next)`` inside an anyio task group and re-raises downstream exceptions
from ``call_next``. Internally the failure travels through the task group as
an ``ExceptionGroup`` (collapsed back to the bare exception only while it
stays single). A gate that does not catch the exception therefore lets it
escape the ENTIRE middleware stack: the client never sees a structured
response, and on the ASGI server the failure surfaces as an
ExceptionGroup-wrapped crash traceback instead of a served 500 — the
worker-killing mode this guard exists to remove.

Every auth gate wraps its ``await call_next(request)`` site with
:func:`guarded_call_next`:

  * any downstream ``Exception`` (including an ``ExceptionGroup`` of
    exceptions) becomes a ``500`` JSONResponse — the client always gets a
    structured answer and the worker keeps serving;
  * a late ``WebSocketDisconnect`` is swallowed with a ``204`` — the peer is
    already gone, there is nothing to answer, and the disconnect must not
    surface as an unhandled ASGI exception;
  * auth decisions made BEFORE ``call_next`` are untouched — 401 / 503
    responses keep their exact semantics. This guard only owns the
    downstream execution, never the verdict.

WebSocket scopes never enter an auth dispatch at all: Starlette routes
non-``http`` scopes around ``BaseHTTPMiddleware`` dispatch. The gates make
that exemption explicit via :func:`scope_is_http` so a future rewiring as a
general ASGI middleware cannot funnel WS handshakes through HTTP auth.
"""
from __future__ import annotations

import logging
from typing import Any, Awaitable, Callable

from fastapi import Request, WebSocketDisconnect
from fastapi.responses import JSONResponse, Response

_log = logging.getLogger(__name__)

# Body of the guarded 500. Matches FastAPI/Starlette's default 500 phrasing
# so clients that already string-match on it keep working; the point of the
# guard is that a JSON envelope arrives at all instead of a dropped
# connection / ExceptionGroup traceback.
INTERNAL_ERROR_BODY = {"detail": "Internal Server Error"}


def scope_is_http(request: Any) -> bool:
    """True unless the request provably carries a non-HTTP scope.

    Lenient on purpose: request doubles used in unit tests may not expose a
    ``scope`` at all — those are treated as HTTP so the auth decision runs
    exactly as before. Only a real ``scope["type"]`` of ``websocket`` (or
    any other non-``http`` type) bypasses the gate.
    """
    scope = getattr(request, "scope", None)
    if not isinstance(scope, dict):
        return True
    return scope.get("type", "http") == "http"


async def guarded_call_next(
    request: Request,
    call_next: Callable[[Request], Awaitable[Response]],
    *,
    gate: str,
) -> Response:
    """Run the downstream stack; never let a downstream exception escape.

    ``gate`` names the calling middleware for the failure log so operators
    can tell which layer converted the crash.
    """
    try:
        return await call_next(request)
    except WebSocketDisconnect:
        # The client disconnected mid-request. There is no peer left to
        # answer; swallowing (with a response nobody will read) keeps the
        # disconnect from surfacing as an unhandled ASGI exception.
        _log.info(
            "%s: client disconnected downstream (WebSocketDisconnect); "
            "no response sent",
            gate,
        )
        return Response(status_code=204)
    except Exception:
        # Covers bare exceptions AND ExceptionGroups of exceptions — the
        # shape a downstream failure takes after travelling through
        # Starlette's BaseHTTPMiddleware task group. Converting here keeps
        # the failure inside the middleware stack: structured 500 out,
        # worker keeps serving, no crash traceback on the server.
        _log.exception(
            "%s: downstream request failed; returning 500 JSONResponse",
            gate,
        )
        return JSONResponse(status_code=500, content=dict(INTERNAL_ERROR_BODY))


__all__ = [
    "INTERNAL_ERROR_BODY",
    "guarded_call_next",
    "scope_is_http",
]
