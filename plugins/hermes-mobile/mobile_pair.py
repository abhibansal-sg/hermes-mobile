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
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Optional
from urllib.parse import quote

# The dashboard's default loopback port (see hermes_cli/main.py: the
# `dashboard` subcommand defaults --port to 9119). A Tailscale Serve handler
# whose Proxy targets this port is the dashboard's public HTTPS front door.
DEFAULT_DASHBOARD_PORT = 9119

# The iOS custom URL scheme + host the app routes on (mirrors
# HermesURLRouter.scheme / the "pair" route in the Swift client).
PAIR_SCHEME = "hermesapp"
PAIR_HOST = "pair"


def mobile_pair_command(args) -> int:
    """Handle ``hermes mobile-pair``. Returns a process exit code."""
    override_url = getattr(args, "url", None)

    dashboard_url = override_url or _detect_dashboard_url()
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
        )
    else:
        deep_link = _build_pair_link(dashboard_url, token)

    print()
    print("  Pair HermesMobile")
    print("  ─────────────────")
    print(f"  Server: {dashboard_url}")
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
# Dashboard URL detection (Tailscale Serve)
# ---------------------------------------------------------------------------

def _detect_dashboard_url(port: int = DEFAULT_DASHBOARD_PORT) -> Optional[str]:
    """Return the public ``https://host:port`` dashboard URL from Tailscale
    Serve, or ``None`` if it can't be determined.

    Strategy: parse ``tailscale serve status --json``; its ``Web`` map is keyed
    by ``hostname:port`` and each entry's ``Handlers`` map path → {"Proxy": ...}.
    We pick the first HTTPS front door whose root ("/") handler proxies to the
    dashboard's loopback port. If no handler matches the dashboard port we fall
    back to the first HTTPS web front door that exists at all.
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
) -> str:
    """Build the ``hermesapp://pair`` deep link with percent-encoded query
    values so the scheme/host stay clean.

    v1 (default): ``hermesapp://pair?url=<url>&token=<token>``. v2 (W3a
    ``--device-token``): ADDITIVE keys ``kind=device&device_id=<id>`` carrying a
    per-device token. ``token`` stays the credential key in BOTH versions so a
    v1 parser never breaks — it ignores the unknown ``kind``/``device_id`` keys
    and treats ``token`` as before."""
    url_q = quote(dashboard_url, safe="")
    token_q = quote(token, safe="")
    link = f"{PAIR_SCHEME}://{PAIR_HOST}?url={url_q}&token={token_q}"
    if kind == "device" and device_id:
        link += f"&kind=device&device_id={quote(device_id, safe='')}"
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
