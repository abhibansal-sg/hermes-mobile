"""
CLI command for pairing the HermesMobile iOS app with this gateway.

Usage:
    hermes mobile-pair          # Print the hermesapp://pair link + an ANSI QR

What it does
------------
1. Resolves the public dashboard URL by reading the local Tailscale Serve
   config (``tailscale serve status --json``): it looks for the HTTPS proxy
   whose handler forwards to the dashboard's loopback port and reports
   ``https://<hostname>:<port>``. If Tailscale Serve isn't configured it falls
   back to printing manual instructions (the operator can pass ``--url``).
2. Reads the dashboard session token from ``<HERMES_HOME>/dashboard.token``
   (overridable via ``HERMES_DASHBOARD_SESSION_TOKEN``).
3. Mints a revocable per-device token by default, then builds the deep link
   ``hermesapp://pair?url=<dashboard-url>&token=<device-token>&kind=device`` and
   renders it as an ANSI QR in the terminal so the phone's camera (or the in-app
   scanner) can pair in one shot. ``--shared-token`` keeps the legacy v1 shape for
   stock gateways that do not support ``/api/devices/issue``.

Security: the token is printed exactly once — embedded in the QR payload and in
the copy/paste deep link the operator reads off the same screen they're already
trusted to see. It is NEVER written to logs, files, or any other channel.

Increment 3a — plugin-side discovery of the Desktop-owned gateway
-----------------------------------------------------------------
``_detect_local_desktop_gateway()`` discovers the gateway that the Hermes
Desktop app owns by reading
``~/Library/Application Support/Hermes/connection.json``:

* ``mode == "remote"``  → return the ``remote.url`` (and token if encoding is
  ``plain``; if ``safeStorage`` / encrypted the token is in macOS Keychain
  and we return the URL-only + ``manual_token=True`` to let the caller prompt).
* ``mode == "local"``   → ephemeral port 9120–9199; probe each port with a
  quick HTTP check for a valid ``/api/status`` response; return the first
  responding URL + ``manual_token=True`` (the token isn't stored on disk in
  local mode — the stock Electron app keeps it in memory only).

Honest limit: pure stock ``local`` mode uses an ephemeral port AND a
memory-only token.  We can discover the port (probe) but CANNOT recover the
token without editing the stock Electron app (which is REJECTED per the plugin
boundary rule).  The caller must either use ``_issue_device_token`` once an
interactive session is available, or fall back to manual token entry in the UI.

The sidecar/embedded-listener idea was considered and REJECTED: the Desktop
Electron app is stock NousResearch — we do NOT add a sidecar or modify it.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Optional, Tuple
from urllib.parse import quote

# ---------------------------------------------------------------------------
# Increment 4a — Address stability types
# ---------------------------------------------------------------------------

# Stability values for ``_PairAddress.address_stability``.
STABILITY_STABLE = "stable"       # MagicDNS hostname or fixed configured port
STABILITY_EPHEMERAL = "ephemeral" # loopback ephemeral (short-lived port or IP)


class _PairAddress:
    """Result of ``_detect_pair_address()``.

    Attributes
    ----------
    url : str
        The resolved gateway URL to embed in the pair QR code.
    address_stability : str
        ``"stable"`` when the address is a MagicDNS hostname (``*.ts.net``) or
        a fixed configured port that survives gateway restarts.
        ``"ephemeral"`` when the address is loopback-ephemeral and may change
        after a restart.
    source : str
        Human-readable description of how the address was resolved.
    """

    __slots__ = ("url", "address_stability", "source")

    def __init__(self, url: str, address_stability: str, source: str) -> None:
        self.url = url
        self.address_stability = address_stability
        self.source = source

# The dashboard's default loopback port (see hermes_cli/main.py: the
# `dashboard` subcommand defaults --port to 9119). A Tailscale Serve handler
# whose Proxy targets this port is the dashboard's public HTTPS front door.
DEFAULT_DASHBOARD_PORT = 9119

# The iOS custom URL scheme + host the app routes on (mirrors
# HermesURLRouter.scheme / the "pair" route in the Swift client).
PAIR_SCHEME = "hermesapp"
PAIR_HOST = "pair"

# ---------------------------------------------------------------------------
# Increment 3a — Desktop gateway discovery constants
# ---------------------------------------------------------------------------

# Path to the Hermes Desktop app's connection state file (macOS only).
# The Desktop app owns this file; we READ it but NEVER write to it.
_DESKTOP_CONNECTION_JSON = (
    Path.home()
    / "Library"
    / "Application Support"
    / "Hermes"
    / "connection.json"
)

# Port range for local-mode ephemeral loopback probes.
# Port 9119 is the well-known dashboard default; 9120–9199 are the ephemeral
# range used by the stock Electron app in local mode.  We probe 9119 first so
# the common "remote user already has :9119 running" case resolves immediately.
_LOCAL_PROBE_PORTS = [DEFAULT_DASHBOARD_PORT] + list(range(9120, 9200))

# Status endpoint the gateway exposes; a 200 + JSON body with a ``status``
# key confirms this is a live Hermes instance.
_STATUS_PATH = "/api/status"

# Per-port HTTP probe timeout (seconds).  Keep short — we probe sequentially.
_PROBE_TIMEOUT_S = 0.8


def mobile_pair_command(args) -> int:
    """Handle ``hermes mobile-pair``. Returns a process exit code."""
    override_url = getattr(args, "url", None)

    # Increment 4a: use _detect_pair_address() to get a stable address when
    # possible.  An explicit --url override bypasses discovery (the operator
    # chose the address; we trust it and mark it stable).
    if override_url:
        dashboard_url = override_url
        address_stability = STABILITY_STABLE
    else:
        pair_addr = _detect_pair_address()
        dashboard_url = pair_addr.url
        address_stability = pair_addr.address_stability

    if not dashboard_url:
        _print_no_url_instructions()
        return 1

    token = _read_dashboard_token()
    if not token:
        print(
            "✗ Could not read the dashboard token.\n"
            "  Expected it at ~/.hermes/dashboard.token, or set\n"
            "  HERMES_DASHBOARD_SESSION_TOKEN in this shell, then re-run."
        )
        return 1

    # W3a QR v2 is the secure default: mint a per-device token from the
    # dashboard and embed that revocable credential in the QR instead of the
    # broad shared dashboard token. ``--shared-token`` keeps the legacy v1 path
    # for stock gateways / old branches.
    if getattr(args, "device_token", True):
        # Mint against the LOCAL listener: on some Macs the tailnet hostname
        # resolves to public Funnel IPs (broken MagicDNS), so an HTTPS
        # round-trip to dashboard_url never reaches this machine's own
        # server (and its Host-check would reject the ts.net name anyway).
        # The QR still embeds dashboard_url for the phone; only the mint
        # call goes local. An explicit --url override keeps minting remote.
        mint_url = override_url or f"http://127.0.0.1:{DEFAULT_DASHBOARD_PORT}"
        issued = _issue_device_token(mint_url, token)
        if issued is None:
            print(
                "✗ Could not mint a device token from the dashboard.\n"
                "  Is this a W3a server with /api/devices/issue?\n"
                "  For a legacy shared-token pairing code, re-run with\n"
                "  --shared-token."
            )
            return 1
        deep_link = _build_pair_link(
            dashboard_url,
            issued["token"],
            kind="device",
            device_id=issued["device_id"],
            address_stability=address_stability,
        )
    else:
        deep_link = _build_pair_link(
            dashboard_url,
            token,
            address_stability=address_stability,
        )

    print()
    print("  Pair HermesMobile")
    print("  ─────────────────")
    print(f"  Server: {dashboard_url}")
    print(f"  Address stability: {address_stability}")
    print("  Chat: start the dashboard with --tui or set HERMES_DASHBOARD_TUI=1.")
    print()

    rendered = _render_ansi_qr(deep_link)
    if rendered is not None:
        print(rendered)
    else:
        print(
            "  (QR rendering needs the 'qrcode' package — `pip install qrcode`.)\n"
            "  Open this link on your phone instead:"
        )

    print()
    print("  Or open this link on the device (it carries the token):")
    print(f"  {deep_link}")
    print()
    print("  In the app: tap “Scan pairing code” and point the camera here.")
    print("  The token is shown only on this screen — don't share a screenshot.")
    print()
    return 0


# ---------------------------------------------------------------------------
# Increment 3a — Desktop-owned gateway discovery
# ---------------------------------------------------------------------------


class _DesktopGatewayResult:
    """Typed result from ``_detect_local_desktop_gateway()``.

    Attributes
    ----------
    url : str
        The discovered gateway base URL (e.g. ``http://127.0.0.1:9119`` or a
        remote HTTPS URL).
    token : str or None
        The gateway auth token if it could be read from ``connection.json``
        (only possible when ``encoding == "plain"``).  ``None`` if the token
        is encrypted (safeStorage) or unavailable (local ephemeral mode).
    manual_token : bool
        ``True`` when the token could NOT be recovered from disk.  The caller
        must prompt the user for the token or use ``_issue_device_token`` once
        an interactive session with the discovered URL is established.
    source : str
        Human-readable description of how the URL was found (for debug logs /
        UI hints).  E.g. ``"connection.json remote"`` or
        ``"loopback probe :9119"``.
    """

    __slots__ = ("url", "token", "manual_token", "source")

    def __init__(
        self,
        url: str,
        token: Optional[str],
        manual_token: bool,
        source: str,
    ) -> None:
        self.url = url
        self.token = token
        self.manual_token = manual_token
        self.source = source


def _read_connection_json(
    path: Path = _DESKTOP_CONNECTION_JSON,
) -> Optional[dict]:
    """Parse the Desktop app's ``connection.json``.

    Returns the parsed dict, or ``None`` if the file is absent, unreadable,
    or contains malformed JSON.  Never raises.
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return None
    try:
        data = json.loads(raw)
    except (ValueError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _probe_local_gateway_port(port: int) -> bool:
    """Return ``True`` if ``http://127.0.0.1:{port}/api/status`` responds with
    a valid Hermes status payload (JSON dict with a ``status`` key).

    Uses ``urllib.request`` so there are no extra dependencies.  All errors
    are silently caught — the caller just skips non-responding ports.

    IMPORTANT: Only loopback (127.0.0.1) is probed — never LAN addresses.
    """
    import urllib.error
    import urllib.request

    url = f"http://127.0.0.1:{port}{_STATUS_PATH}"
    req = urllib.request.Request(
        url,
        headers={"Host": "127.0.0.1"},
    )
    try:
        with urllib.request.urlopen(req, timeout=_PROBE_TIMEOUT_S) as resp:
            if resp.status != 200:
                return False
            body = resp.read(4096).decode("utf-8", errors="replace")
        data = json.loads(body)
        # A genuine Hermes status response is a JSON object with a ``status``
        # key.  Accept any truthy value — we don't enforce the exact string.
        return isinstance(data, dict) and bool(data.get("status"))
    except Exception:  # noqa: BLE001
        return False


def _detect_local_desktop_gateway(
    connection_json_path: Path = _DESKTOP_CONNECTION_JSON,
) -> Optional["_DesktopGatewayResult"]:
    """Discover the gateway owned by the Hermes Desktop app.

    Strategy
    --------
    1. Read ``connection.json`` (the Desktop app's connection state).
    2. If ``mode == "remote"`` and ``remote.url`` is non-empty → return that
       URL.  If ``encoding == "plain"``, also return the token.  If
       ``encoding`` is ``"safeStorage"`` or anything else (encrypted), return
       URL-only + ``manual_token=True``.
    3. If ``mode == "local"`` (ephemeral loopback) → probe ports
       ``[9119, 9120..9199]`` with a quick ``/api/status`` check.  Return the
       first responding URL + ``manual_token=True`` because the stock Electron
       app does NOT persist the ephemeral token to disk.
    4. If ``connection.json`` is absent/malformed → return ``None`` (caller
       falls through to the Tailscale Serve path).

    Honest limit
    ------------
    Pure ``local`` mode: the Desktop app binds an ephemeral port AND keeps the
    auth token in memory only.  We can DISCOVER the port (probe) but cannot
    recover the token without modifying the stock Electron app (REJECTED per
    the plugin-boundary rule).  ``manual_token=True`` signals this to the
    caller.  The recommended resolution is:

    * Use ``_issue_device_token`` once the user provides any valid token for
      the discovered URL (e.g. from the Desktop app's Settings → Copy token).
    * Or fall back to the Tailscale Serve path (remote mode).

    Sidecar / embedded-listener: REJECTED.  The Electron app is stock
    NousResearch — we do NOT add a subprocess or modify it.
    """
    data = _read_connection_json(connection_json_path)
    if data is None:
        return None

    mode = data.get("mode", "")

    if mode == "remote":
        remote = data.get("remote") or {}
        if not isinstance(remote, dict):
            return None
        url = (remote.get("url") or "").strip()
        if not url:
            return None
        encoding = (remote.get("encoding") or "plain").lower()
        if encoding == "plain":
            token = (remote.get("token") or "").strip() or None
            return _DesktopGatewayResult(
                url=url,
                token=token,
                manual_token=(token is None),
                source="connection.json remote",
            )
        else:
            # Encrypted (e.g. "safeStorage"): token is in macOS Keychain /
            # Electron safeStorage — we can't read it without the Electron
            # app's context.  Return URL only; caller must prompt for token.
            return _DesktopGatewayResult(
                url=url,
                token=None,
                manual_token=True,
                source=f"connection.json remote (encrypted token: {encoding})",
            )

    if mode == "local":
        # Ephemeral port + memory-only token: probe the known range.
        for port in _LOCAL_PROBE_PORTS:
            if _probe_local_gateway_port(port):
                return _DesktopGatewayResult(
                    url=f"http://127.0.0.1:{port}",
                    token=None,
                    manual_token=True,
                    source=f"loopback probe :{port}",
                )
        # No port responded — gateway is likely not running.
        return None

    # Unknown mode — don't crash, just return None.
    return None


# ---------------------------------------------------------------------------
# Dashboard URL detection (Tailscale Serve)
# ---------------------------------------------------------------------------

def _detect_dashboard_url(port: int = DEFAULT_DASHBOARD_PORT) -> Optional[str]:
    """Return the public ``https://host:port`` dashboard URL from Tailscale
    Serve, or ``None`` if it can't be determined.

    Detection order (first success wins)
    -------------------------------------
    1. **Desktop-owned gateway** (Increment 3a): read
       ``~/Library/Application Support/Hermes/connection.json``.  If the
       Desktop app is in ``remote`` mode with a non-empty URL, use that
       directly (no probe needed).  If in ``local`` mode, probe the ephemeral
       loopback port range.  When ``manual_token=True`` is signalled only the
       URL is returned here — the caller is responsible for obtaining the
       token (e.g. via ``_issue_device_token`` or manual entry).
    2. **Tailscale Serve** (existing logic): parse
       ``tailscale serve status --json``; pick the HTTPS front door whose
       root handler proxies to the dashboard's loopback port.

    The Desktop-discovery step is a pure addition — the Tailscale-Serve path
    is kept intact as a fallback so existing setups are unaffected.
    """
    # --- Step 1: Desktop-owned gateway discovery (Increment 3a) ---
    desktop = _detect_local_desktop_gateway()
    if desktop is not None:
        # Return the URL regardless of whether the token is available; the
        # command flow will use the existing token-reading / minting path
        # which may succeed for remote mode (where the token is in
        # dashboard.token), or fall back to prompting for local mode.
        return desktop.url

    # --- Step 2: Tailscale Serve (existing fallback) ---
    status = _tailscale_serve_status()
    if not status:
        return None

    web = status.get("Web") or {}
    if not isinstance(web, dict):
        return None

    proxy_needle = f":{port}"
    fallback: Optional[str] = None

    for host_port, entry in web.items():
        if not isinstance(entry, dict):
            continue
        handlers = entry.get("Handlers") or {}
        if not isinstance(handlers, dict):
            continue

        # Remember the first web front door as a coarse fallback.
        if fallback is None:
            fallback = f"https://{host_port}"

        for _path, handler in handlers.items():
            if not isinstance(handler, dict):
                continue
            proxy = handler.get("Proxy")
            if isinstance(proxy, str) and proxy_needle in proxy:
                # Matched the dashboard's loopback port — exact hit.
                return f"https://{host_port}"

    return fallback


def _tailscale_serve_status() -> Optional[dict]:
    """Run ``tailscale serve status --json`` and parse it; ``None`` on any
    failure (binary missing, non-zero exit, bad JSON, timeout)."""
    binary = shutil.which("tailscale")
    if not binary:
        return None
    try:
        proc = subprocess.run(
            [binary, "serve", "status", "--json"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        data = json.loads(proc.stdout)
    except (ValueError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


# ---------------------------------------------------------------------------
# Increment 4a — Tailscale node status (MagicDNS resolution)
# ---------------------------------------------------------------------------


def _tailscale_node_status() -> Optional[dict]:
    """Run ``tailscale status --json`` and return the parsed dict.

    This is distinct from ``_tailscale_serve_status()`` (which calls
    ``tailscale serve status --json``).  The node-status command exposes the
    ``Self`` block which carries ``DNSName`` (the MagicDNS hostname, e.g.
    ``mymac.tailnet.ts.net.``) and ``MagicDNSSuffix`` (e.g.
    ``tailnet.ts.net``).  These are the two stable fields we read for address
    stability.

    Returns ``None`` on any failure (binary missing, non-zero exit, bad JSON,
    timeout, or non-dict body).  Never raises.
    """
    binary = shutil.which("tailscale")
    if not binary:
        return None
    try:
        proc = subprocess.run(
            [binary, "status", "--json"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        data = json.loads(proc.stdout)
    except (ValueError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _resolve_magicdns_hostname(port: int = DEFAULT_DASHBOARD_PORT) -> Optional[str]:
    """Return a stable ``https://<magicdns-host>:<port>`` URL when this node is
    on a Tailscale tailnet with MagicDNS enabled, or ``None`` otherwise.

    Reads ``Self.DNSName`` from ``tailscale status --json``.  The DNSName
    value typically has a trailing dot (e.g. ``mymac.tailnet.ts.net.``); we
    strip it so the resulting URL is valid.

    We require that ``MagicDNSSuffix`` is non-empty (confirming MagicDNS is
    active on this tailnet) and that ``DNSName`` ends with the suffix.
    If either condition fails we return ``None`` so the caller falls through
    to the LAN / loopback path.

    The port argument uses the same default as ``_detect_dashboard_url()``
    (the dashboard's well-known loopback port) so callers don't need to pass
    it unless they have a different serve port.
    """
    status = _tailscale_node_status()
    if not isinstance(status, dict):
        return None

    self_node = status.get("Self")
    if not isinstance(self_node, dict):
        return None

    dns_name: str = (self_node.get("DNSName") or "").strip().rstrip(".")
    magic_suffix: str = (status.get("MagicDNSSuffix") or "").strip().rstrip(".")

    if not dns_name or not magic_suffix:
        return None

    # Sanity: the hostname must end with the tailnet's MagicDNS suffix.
    if not dns_name.endswith(magic_suffix):
        return None

    return f"https://{dns_name}:{port}"


def _detect_serve_url(port: int = DEFAULT_DASHBOARD_PORT) -> Optional[str]:
    """Extract the Tailscale Serve HTTPS front-door URL (without the Desktop
    gateway discovery step).  Used internally by ``_detect_pair_address()`` so
    the Tailscale Serve step is only reached when both MagicDNS and Desktop
    discovery have already been tried.

    Logic mirrors the Tailscale-Serve block in ``_detect_dashboard_url()``
    exactly — kept in sync by construction (one helper, two callers).
    """
    status = _tailscale_serve_status()
    if not status:
        return None

    web = status.get("Web") or {}
    if not isinstance(web, dict):
        return None

    proxy_needle = f":{port}"
    fallback: Optional[str] = None

    for host_port, entry in web.items():
        if not isinstance(entry, dict):
            continue
        handlers = entry.get("Handlers") or {}
        if not isinstance(handlers, dict):
            continue

        if fallback is None:
            fallback = f"https://{host_port}"

        for _path, handler in handlers.items():
            if not isinstance(handler, dict):
                continue
            proxy = handler.get("Proxy")
            if isinstance(proxy, str) and proxy_needle in proxy:
                return f"https://{host_port}"

    return fallback


def _detect_pair_address(port: int = DEFAULT_DASHBOARD_PORT) -> "_PairAddress":
    """Resolve the best available pairing/dashboard URL with an explicit
    ``address_stability`` signal.

    Priority (first success wins)
    --------------------------------
    1. **Tailscale MagicDNS hostname** (``stable``) — ``tailscale status --json``
       ``Self.DNSName``.  Reuses the same trusted Tailscale binary and JSON
       parsing already used by ``_tailscale_serve_status()``; no new dependency.
    2. **Desktop-owned gateway** (stability depends on source) — reads
       ``connection.json`` as in Increment 3a.  A ``remote`` URL is ``stable``
       (explicit configured address); a loopback probe result is ``ephemeral``.
    3. **Tailscale Serve HTTPS front door** (``stable``) — existing Serve path
       (``tailscale serve status --json``); Serve publishes over the MagicDNS
       hostname so its result is stable.
    4. **Loopback ephemeral fallback** (``ephemeral``) — ``None``-returning
       fallback: returns a loopback URL on the default port, marked ephemeral.

    This function is the increment-4a entry point.  ``_detect_dashboard_url()``
    is kept UNCHANGED (returns ``Optional[str]``) so existing callers and tests
    are unaffected.
    """
    # --- Priority 1: MagicDNS hostname ---
    magicdns_url = _resolve_magicdns_hostname(port)
    if magicdns_url:
        return _PairAddress(
            url=magicdns_url,
            address_stability=STABILITY_STABLE,
            source="tailscale magicdns",
        )

    # --- Priority 2: Desktop-owned gateway (connection.json) ---
    desktop = _detect_local_desktop_gateway()
    if desktop is not None:
        # A remote URL is a configured, stable address.
        # A loopback probe result is ephemeral (port may change after restart).
        if "remote" in desktop.source:
            stability = STABILITY_STABLE
        else:
            stability = STABILITY_EPHEMERAL
        return _PairAddress(
            url=desktop.url,
            address_stability=stability,
            source=f"connection.json ({desktop.source})",
        )

    # --- Priority 3: Tailscale Serve HTTPS front door ---
    # Use _detect_serve_url() directly so we don't re-run Desktop discovery.
    serve_url = _detect_serve_url(port)
    if serve_url:
        return _PairAddress(
            url=serve_url,
            address_stability=STABILITY_STABLE,
            source="tailscale serve",
        )

    # --- Priority 4: Ephemeral loopback fallback ---
    return _PairAddress(
        url=f"http://127.0.0.1:{port}",
        address_stability=STABILITY_EPHEMERAL,
        source="loopback fallback",
    )


def _print_no_url_instructions() -> None:
    print(
        "\n  Couldn't auto-detect a public HTTPS URL for the dashboard.\n\n"
        "  HermesMobile needs to reach the gateway over Tailscale Serve.\n"
        "  Set it up, then re-run `hermes mobile-pair`:\n\n"
        f"    tailscale serve --bg https / http://127.0.0.1:{DEFAULT_DASHBOARD_PORT}\n\n"
        "  Already have a URL? Pass it explicitly:\n\n"
        "    hermes mobile-pair --url https://your-mac.tailnet.ts.net:9443\n"
    )


# ---------------------------------------------------------------------------
# Token
# ---------------------------------------------------------------------------

def _read_dashboard_token() -> Optional[str]:
    """Resolve the dashboard session token: env override first, then the
    active-profile ``<HERMES_HOME>/dashboard.token`` file."""
    env_token = os.environ.get("HERMES_DASHBOARD_SESSION_TOKEN", "").strip()
    if env_token:
        return env_token

    try:
        from hermes_constants import get_hermes_home

        token_path = get_hermes_home() / "dashboard.token"
    except Exception:  # pragma: no cover - defensive import fallback
        token_path = Path.home() / ".hermes" / "dashboard.token"
    try:
        token = token_path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return token or None


# ---------------------------------------------------------------------------
# Deep link + QR
# ---------------------------------------------------------------------------

def _build_pair_link(
    dashboard_url: str,
    token: str,
    *,
    kind: Optional[str] = None,
    device_id: Optional[str] = None,
    address_stability: Optional[str] = None,
) -> str:
    """Build the ``hermesapp://pair`` deep link with percent-encoded query
    values so the scheme/host stay clean.

    v1 (default): ``hermesapp://pair?url=<url>&token=<token>``. v2 (W3a
    ``--device-token``): ADDITIVE keys ``kind=device&device_id=<id>`` carrying a
    per-device token. ``token`` stays the credential key in BOTH versions so a
    v1 parser never breaks — it ignores the unknown ``kind``/``device_id`` keys
    and treats ``token`` as before.

    Increment 4a: ``address_stability`` is an ADDITIVE optional key
    (``addr_stability=stable|ephemeral``).  Absent when ``None`` so v1/v2
    parsers that don't know about it are completely unaffected.  The iOS client
    uses this hint to decide whether to persist the URL as a stable long-term
    address or treat it as ephemeral.
    """
    url_q = quote(dashboard_url, safe="")
    token_q = quote(token, safe="")
    link = f"{PAIR_SCHEME}://{PAIR_HOST}?url={url_q}&token={token_q}"
    if kind == "device" and device_id:
        link += f"&kind=device&device_id={quote(device_id, safe='')}"
    if address_stability:
        link += f"&addr_stability={quote(address_stability, safe='')}"
    return link


# Device-issue endpoint paths, tried in order. The plugin mount is the
# canonical path after the ABH-88 de-patch; the legacy top-level path keeps
# pairing working against servers that predate it (e.g. the live dashboard
# until its next redeploy).
_DEVICE_ISSUE_PATHS = (
    "/api/plugins/hermes-mobile/devices/issue",
    "/api/devices/issue",
)


def _issue_device_token(dashboard_url: str, shared_token: str) -> Optional[dict]:
    """Mint a per-device token via the dashboard (authenticating with the
    shared token). Tries the plugin-mounted route first, then the legacy
    top-level route for pre-de-patch servers. Returns the issue response
    dict (``device_id``/``token``/...) or None on any failure. The token is
    handled in-memory only and embedded once in the QR — never logged."""
    import json as _json
    import urllib.error
    import urllib.request

    body = _json.dumps({"device_name": "Paired device", "platform": "ios"}).encode()
    for path in _DEVICE_ISSUE_PATHS:
        issue_url = dashboard_url.rstrip("/") + path
        req = urllib.request.Request(
            issue_url,
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Host": "127.0.0.1",
                "X-Hermes-Session-Token": shared_token,
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status != 200:
                    continue
                data = _json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, OSError, ValueError):
            continue
        if (
            isinstance(data, dict)
            and data.get("token")
            and data.get("device_id")
        ):
            return data
    return None


def _render_ansi_qr(payload: str) -> Optional[str]:
    """Render ``payload`` as a compact ANSI QR string, or ``None`` if the
    optional ``qrcode`` dependency isn't installed.

    Uses ``qrcode``'s half-block ASCII renderer (two rows per character cell)
    so the code stays scannable in a normal-height terminal window.
    """
    try:
        import qrcode  # type: ignore
    except ImportError:
        return None

    qr = qrcode.QRCode(
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        border=2,
    )
    qr.add_data(payload)
    qr.make(fit=True)

    import io

    buf = io.StringIO()
    # invert=True makes the modules render with the terminal's default light-on
    # -dark expectation flipped to dark-on-light, which scans more reliably in
    # both dark and light terminals when combined with the half-block glyphs.
    qr.print_ascii(out=buf, tty=False, invert=True)
    return buf.getvalue()
