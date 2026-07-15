"""Increment 4a — Address stability tests for ``_detect_pair_address()``,
``_resolve_magicdns_hostname()``, and ``_tailscale_node_status()``.

Covers the three required cases:
  (i)  Tailscale status reports a MagicDNS hostname → result uses it +
       ``address_stability == "stable"``.
  (ii) Only ephemeral loopback available (no tailnet) → ``address_stability
       == "ephemeral"`` + existing behavior byte-for-byte unchanged (the
       legacy fallback URL is ``http://127.0.0.1:<port>``).
  (iii) Malformed / absent ``tailscale status`` output → clean fallback, NO
       crash.

All subprocess + filesystem calls are mocked; no real Tailscale is required.
"""

from __future__ import annotations

import json
import subprocess
from types import SimpleNamespace
from unittest.mock import MagicMock, patch
from urllib.parse import parse_qs, urlparse

import pytest

from tests.plugins.hermes_mobile.conftest import load_plugin_module

mobile_pair = load_plugin_module("mobile_pair")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_ts_status(dns_name: str, magic_suffix: str) -> dict:
    """Build a minimal ``tailscale status --json`` response dict."""
    return {
        "Self": {
            "DNSName": dns_name,
            "TailscaleIPs": ["100.64.0.1"],
            "Online": True,
        },
        "MagicDNSSuffix": magic_suffix,
    }


# ---------------------------------------------------------------------------
# _tailscale_node_status — raw subprocess wrapper
# ---------------------------------------------------------------------------


class TestTailscaleNodeStatus:
    """Unit tests for the low-level ``_tailscale_node_status()`` helper."""

    def test_returns_parsed_dict_on_success(self, monkeypatch):
        payload = _make_ts_status("mymac.tailnet.ts.net.", "tailnet.ts.net")
        monkeypatch.setattr("shutil.which", lambda _: "/usr/bin/tailscale")
        monkeypatch.setattr(
            "subprocess.run",
            lambda *a, **kw: SimpleNamespace(
                returncode=0, stdout=json.dumps(payload), stderr=""
            ),
        )
        result = mobile_pair._tailscale_node_status()
        assert result is not None
        assert result["Self"]["DNSName"] == "mymac.tailnet.ts.net."

    def test_returns_none_when_binary_absent(self, monkeypatch):
        monkeypatch.setattr("shutil.which", lambda _: None)
        assert mobile_pair._tailscale_node_status() is None

    def test_returns_none_on_nonzero_exit(self, monkeypatch):
        monkeypatch.setattr("shutil.which", lambda _: "/usr/bin/tailscale")
        monkeypatch.setattr(
            "subprocess.run",
            lambda *a, **kw: SimpleNamespace(returncode=1, stdout="", stderr="err"),
        )
        assert mobile_pair._tailscale_node_status() is None

    def test_returns_none_on_empty_stdout(self, monkeypatch):
        monkeypatch.setattr("shutil.which", lambda _: "/usr/bin/tailscale")
        monkeypatch.setattr(
            "subprocess.run",
            lambda *a, **kw: SimpleNamespace(returncode=0, stdout="   ", stderr=""),
        )
        assert mobile_pair._tailscale_node_status() is None

    def test_returns_none_on_malformed_json(self, monkeypatch):
        monkeypatch.setattr("shutil.which", lambda _: "/usr/bin/tailscale")
        monkeypatch.setattr(
            "subprocess.run",
            lambda *a, **kw: SimpleNamespace(
                returncode=0, stdout="not json }{{{", stderr=""
            ),
        )
        assert mobile_pair._tailscale_node_status() is None

    def test_returns_none_on_subprocess_error(self, monkeypatch):
        monkeypatch.setattr("shutil.which", lambda _: "/usr/bin/tailscale")

        def _boom(*a, **kw):
            raise subprocess.SubprocessError("broken pipe")

        monkeypatch.setattr("subprocess.run", _boom)
        assert mobile_pair._tailscale_node_status() is None

    def test_returns_none_for_json_list(self, monkeypatch):
        """JSON body that is a list (not a dict) must return None."""
        monkeypatch.setattr("shutil.which", lambda _: "/usr/bin/tailscale")
        monkeypatch.setattr(
            "subprocess.run",
            lambda *a, **kw: SimpleNamespace(
                returncode=0, stdout='["not", "a", "dict"]', stderr=""
            ),
        )
        assert mobile_pair._tailscale_node_status() is None


# ---------------------------------------------------------------------------
# _resolve_magicdns_hostname
# ---------------------------------------------------------------------------


class TestResolveMagicdnsHostname:
    """Tests for the MagicDNS hostname resolver."""

    def _patch_node_status(self, monkeypatch, payload):
        monkeypatch.setattr(mobile_pair, "_tailscale_node_status", lambda: payload)

    def test_returns_https_url_for_valid_magicdns(self, monkeypatch):
        """Case (i): MagicDNS present → stable ``https://host:port`` URL."""
        self._patch_node_status(
            monkeypatch,
            _make_ts_status("mymac.tailnet.ts.net.", "tailnet.ts.net"),
        )
        url = mobile_pair._resolve_magicdns_hostname(port=9119)
        assert url == "https://mymac.tailnet.ts.net:9119"

    def test_strips_trailing_dot_from_dns_name(self, monkeypatch):
        """DNSName may carry a trailing dot; the URL must not."""
        self._patch_node_status(
            monkeypatch,
            _make_ts_status("host.ts.net.", "ts.net"),
        )
        url = mobile_pair._resolve_magicdns_hostname()
        assert url is not None
        assert not url.split("/")[2].endswith(".")

    def test_returns_none_when_no_tailscale_binary(self, monkeypatch):
        self._patch_node_status(monkeypatch, None)
        assert mobile_pair._resolve_magicdns_hostname() is None

    def test_returns_none_when_self_block_missing(self, monkeypatch):
        self._patch_node_status(
            monkeypatch, {"MagicDNSSuffix": "tailnet.ts.net"}
        )
        assert mobile_pair._resolve_magicdns_hostname() is None

    def test_returns_none_when_dns_name_empty(self, monkeypatch):
        payload = _make_ts_status("", "tailnet.ts.net")
        payload["Self"]["DNSName"] = ""
        self._patch_node_status(monkeypatch, payload)
        assert mobile_pair._resolve_magicdns_hostname() is None

    def test_returns_none_when_magic_suffix_empty(self, monkeypatch):
        payload = _make_ts_status("mymac.tailnet.ts.net.", "")
        self._patch_node_status(monkeypatch, payload)
        assert mobile_pair._resolve_magicdns_hostname() is None

    def test_returns_none_when_dns_name_not_in_suffix(self, monkeypatch):
        """DNSName that does not end with MagicDNSSuffix is rejected."""
        payload = _make_ts_status("mymac.other.net.", "tailnet.ts.net")
        self._patch_node_status(monkeypatch, payload)
        assert mobile_pair._resolve_magicdns_hostname() is None

    def test_uses_custom_port(self, monkeypatch):
        self._patch_node_status(
            monkeypatch,
            _make_ts_status("box.corp.ts.net.", "corp.ts.net"),
        )
        url = mobile_pair._resolve_magicdns_hostname(port=9443)
        assert url is not None
        assert ":9443" in url


# ---------------------------------------------------------------------------
# _detect_pair_address — the three required spec cases
# ---------------------------------------------------------------------------


class TestDetectPairAddress:
    """Spec-required tests for ``_detect_pair_address()``.

    Case (i):  MagicDNS available → stable address.
    Case (ii): No tailnet / only loopback → ephemeral fallback.
    Case (iii): Malformed tailscale output → clean fallback, no crash.
    """

    # ------------------------------------------------------------------
    # Case (i): Tailscale MagicDNS hostname present
    # ------------------------------------------------------------------

    def test_case_i_magicdns_hostname_used_and_stability_is_stable(self, monkeypatch):
        """(i) tailscale status reports MagicDNS → result uses it + stable."""
        monkeypatch.setattr(
            mobile_pair,
            "_resolve_magicdns_hostname",
            lambda port=mobile_pair.DEFAULT_DASHBOARD_PORT: "https://mymac.tailnet.ts.net:9119",
        )
        monkeypatch.setattr(mobile_pair, "_detect_local_desktop_gateway", lambda: None)
        monkeypatch.setattr(mobile_pair, "_detect_serve_url", lambda port=9119: None)

        result = mobile_pair._detect_pair_address()

        assert result.url == "https://mymac.tailnet.ts.net:9119"
        assert result.address_stability == mobile_pair.STABILITY_STABLE
        assert result.address_stability == "stable"

    def test_case_i_magicdns_wins_over_desktop_and_serve(self, monkeypatch):
        """MagicDNS is checked first; Desktop and Serve must not be called."""
        magicdns_called = {"n": 0}
        desktop_called = {"n": 0}
        serve_called = {"n": 0}

        def _magicdns(port=mobile_pair.DEFAULT_DASHBOARD_PORT):
            magicdns_called["n"] += 1
            return "https://mymac.tailnet.ts.net:9119"

        def _desktop():
            desktop_called["n"] += 1
            return None

        def _serve(port=mobile_pair.DEFAULT_DASHBOARD_PORT):
            serve_called["n"] += 1
            return None

        monkeypatch.setattr(mobile_pair, "_resolve_magicdns_hostname", _magicdns)
        monkeypatch.setattr(mobile_pair, "_detect_local_desktop_gateway", _desktop)
        monkeypatch.setattr(mobile_pair, "_detect_serve_url", _serve)

        result = mobile_pair._detect_pair_address()

        assert result.address_stability == "stable"
        assert magicdns_called["n"] == 1
        assert desktop_called["n"] == 0  # short-circuits after MagicDNS
        assert serve_called["n"] == 0

    def test_case_i_magicdns_url_embedded_in_pair_link(self, monkeypatch):
        """MagicDNS URL surfaces in the pair link as the ``url`` parameter."""
        monkeypatch.setattr(
            mobile_pair,
            "_resolve_magicdns_hostname",
            lambda port=mobile_pair.DEFAULT_DASHBOARD_PORT: "https://mymac.tailnet.ts.net:9119",
        )
        monkeypatch.setattr(mobile_pair, "_detect_local_desktop_gateway", lambda: None)
        monkeypatch.setattr(mobile_pair, "_detect_serve_url", lambda port=9119: None)

        result = mobile_pair._detect_pair_address()
        link = mobile_pair._build_pair_link(
            result.url, "TOK", address_stability=result.address_stability
        )
        q = parse_qs(urlparse(link).query)
        assert q["url"] == ["https://mymac.tailnet.ts.net:9119"]
        assert q["addr_stability"] == ["stable"]

    # ------------------------------------------------------------------
    # Case (ii): No tailnet — only ephemeral loopback available
    # ------------------------------------------------------------------

    def test_case_ii_no_tailnet_stability_is_ephemeral(self, monkeypatch):
        """(ii) No tailnet / only loopback → address_stability == 'ephemeral'."""
        monkeypatch.setattr(
            mobile_pair, "_resolve_magicdns_hostname", lambda port=9119: None
        )
        monkeypatch.setattr(mobile_pair, "_detect_local_desktop_gateway", lambda: None)
        monkeypatch.setattr(mobile_pair, "_detect_serve_url", lambda port=9119: None)

        result = mobile_pair._detect_pair_address()

        assert result.address_stability == mobile_pair.STABILITY_EPHEMERAL
        assert result.address_stability == "ephemeral"

    def test_case_ii_ephemeral_url_is_loopback_default_port(self, monkeypatch):
        """(ii) Fallback URL is ``http://127.0.0.1:<default_port>``."""
        monkeypatch.setattr(
            mobile_pair, "_resolve_magicdns_hostname", lambda port=9119: None
        )
        monkeypatch.setattr(mobile_pair, "_detect_local_desktop_gateway", lambda: None)
        monkeypatch.setattr(mobile_pair, "_detect_serve_url", lambda port=9119: None)

        result = mobile_pair._detect_pair_address()

        expected_url = f"http://127.0.0.1:{mobile_pair.DEFAULT_DASHBOARD_PORT}"
        assert result.url == expected_url

    def test_case_ii_ephemeral_loopback_url_unchanged_from_before(self, monkeypatch):
        """(ii) The existing loopback fallback behavior is byte-for-byte identical.

        This test constructs the expected URL using the same formula as the old
        detect_dashboard_url() fallback — both must produce the same string.
        """
        monkeypatch.setattr(
            mobile_pair, "_resolve_magicdns_hostname", lambda port=9119: None
        )
        monkeypatch.setattr(mobile_pair, "_detect_local_desktop_gateway", lambda: None)
        monkeypatch.setattr(mobile_pair, "_detect_serve_url", lambda port=9119: None)

        result = mobile_pair._detect_pair_address()

        # The old ephemeral loopback was built as:
        # ``f"http://127.0.0.1:{DEFAULT_DASHBOARD_PORT}"``
        legacy_url = f"http://127.0.0.1:{mobile_pair.DEFAULT_DASHBOARD_PORT}"
        assert result.url == legacy_url
        assert result.address_stability == "ephemeral"

    def test_case_ii_ephemeral_pair_link_carries_stability_field(self, monkeypatch):
        """(ii) The ephemeral path still produces a valid pair link with
        addr_stability=ephemeral when _build_pair_link is called."""
        monkeypatch.setattr(
            mobile_pair, "_resolve_magicdns_hostname", lambda port=9119: None
        )
        monkeypatch.setattr(mobile_pair, "_detect_local_desktop_gateway", lambda: None)
        monkeypatch.setattr(mobile_pair, "_detect_serve_url", lambda port=9119: None)

        result = mobile_pair._detect_pair_address()
        link = mobile_pair._build_pair_link(
            result.url, "TOK", address_stability=result.address_stability
        )
        q = parse_qs(urlparse(link).query)
        assert q["addr_stability"] == ["ephemeral"]

    # ------------------------------------------------------------------
    # Case (iii): Malformed / absent tailscale output → clean fallback
    # ------------------------------------------------------------------

    def test_case_iii_malformed_json_from_tailscale_does_not_crash(self, monkeypatch):
        """(iii) ``tailscale status`` emits invalid JSON → no exception, clean fallback."""
        monkeypatch.setattr("shutil.which", lambda _: "/usr/bin/tailscale")
        monkeypatch.setattr(
            "subprocess.run",
            lambda *a, **kw: SimpleNamespace(
                returncode=0, stdout="<<<not valid json>>>", stderr=""
            ),
        )
        monkeypatch.setattr(mobile_pair, "_detect_local_desktop_gateway", lambda: None)
        monkeypatch.setattr(mobile_pair, "_detect_serve_url", lambda port=9119: None)

        # Must not raise; must return a valid _PairAddress.
        result = mobile_pair._detect_pair_address()
        assert result is not None
        assert result.address_stability == "ephemeral"
        assert result.url  # non-empty URL

    def test_case_iii_tailscale_binary_absent_clean_fallback(self, monkeypatch):
        """(iii) No tailscale binary → fall through without crashing."""
        monkeypatch.setattr("shutil.which", lambda _: None)
        monkeypatch.setattr(mobile_pair, "_detect_local_desktop_gateway", lambda: None)
        monkeypatch.setattr(mobile_pair, "_detect_serve_url", lambda port=9119: None)

        result = mobile_pair._detect_pair_address()
        assert result is not None
        assert result.address_stability == "ephemeral"

    def test_case_iii_subprocess_raises_clean_fallback(self, monkeypatch):
        """(iii) subprocess.run raises → fall through without crashing."""
        monkeypatch.setattr("shutil.which", lambda _: "/usr/bin/tailscale")

        def _boom(*a, **kw):
            raise OSError("no such file")

        monkeypatch.setattr("subprocess.run", _boom)
        monkeypatch.setattr(mobile_pair, "_detect_local_desktop_gateway", lambda: None)
        monkeypatch.setattr(mobile_pair, "_detect_serve_url", lambda port=9119: None)

        result = mobile_pair._detect_pair_address()
        assert result is not None
        assert result.address_stability == "ephemeral"

    def test_case_iii_tailscale_nonzero_exit_clean_fallback(self, monkeypatch):
        """(iii) tailscale exits non-zero → fall through without crashing."""
        monkeypatch.setattr("shutil.which", lambda _: "/usr/bin/tailscale")
        monkeypatch.setattr(
            "subprocess.run",
            lambda *a, **kw: SimpleNamespace(returncode=2, stdout="", stderr="err"),
        )
        monkeypatch.setattr(mobile_pair, "_detect_local_desktop_gateway", lambda: None)
        monkeypatch.setattr(mobile_pair, "_detect_serve_url", lambda port=9119: None)

        result = mobile_pair._detect_pair_address()
        assert result is not None
        assert result.address_stability == "ephemeral"

    def test_case_iii_missing_self_block_clean_fallback(self, monkeypatch):
        """(iii) Valid JSON but Self block absent → fall through without crashing."""
        monkeypatch.setattr("shutil.which", lambda _: "/usr/bin/tailscale")
        monkeypatch.setattr(
            "subprocess.run",
            lambda *a, **kw: SimpleNamespace(
                returncode=0,
                stdout=json.dumps({"MagicDNSSuffix": "tailnet.ts.net"}),
                stderr="",
            ),
        )
        monkeypatch.setattr(mobile_pair, "_detect_local_desktop_gateway", lambda: None)
        monkeypatch.setattr(mobile_pair, "_detect_serve_url", lambda port=9119: None)

        result = mobile_pair._detect_pair_address()
        assert result is not None
        assert result.address_stability == "ephemeral"


# ---------------------------------------------------------------------------
# _build_pair_link — addr_stability field is additive
# ---------------------------------------------------------------------------


class TestBuildPairLinkStability:
    """Confirm addr_stability is purely additive — old callers unaffected."""

    def test_addr_stability_absent_when_not_passed(self):
        link = mobile_pair._build_pair_link("https://h.ts.net:9119", "TOK")
        assert "addr_stability" not in link

    def test_addr_stability_stable_embedded(self):
        link = mobile_pair._build_pair_link(
            "https://h.ts.net:9119", "TOK", address_stability="stable"
        )
        q = parse_qs(urlparse(link).query)
        assert q["addr_stability"] == ["stable"]

    def test_addr_stability_ephemeral_embedded(self):
        link = mobile_pair._build_pair_link(
            "http://127.0.0.1:9119", "TOK", address_stability="ephemeral"
        )
        q = parse_qs(urlparse(link).query)
        assert q["addr_stability"] == ["ephemeral"]

    def test_existing_v1_keys_unchanged(self):
        """v1 url + token keys are never modified by the stability addition."""
        link = mobile_pair._build_pair_link(
            "https://h.ts.net", "MYTOKEN", address_stability="stable"
        )
        q = parse_qs(urlparse(link).query)
        assert q["url"] == ["https://h.ts.net"]
        assert q["token"] == ["MYTOKEN"]

    def test_existing_v2_keys_coexist(self):
        """v2 kind/device_id coexist with addr_stability."""
        link = mobile_pair._build_pair_link(
            "https://h.ts.net",
            "DEVTOK",
            kind="device",
            device_id="dev_1",
            address_stability="stable",
        )
        q = parse_qs(urlparse(link).query)
        assert q["kind"] == ["device"]
        assert q["device_id"] == ["dev_1"]
        assert q["addr_stability"] == ["stable"]


# ---------------------------------------------------------------------------
# _PairAddress attributes
# ---------------------------------------------------------------------------


class TestPairAddressAttributes:
    def test_has_url_stability_source(self):
        pa = mobile_pair._PairAddress(
            url="https://h.ts.net:9119",
            address_stability="stable",
            source="tailscale magicdns",
        )
        assert pa.url == "https://h.ts.net:9119"
        assert pa.address_stability == "stable"
        assert pa.source == "tailscale magicdns"

    def test_stability_constants(self):
        assert mobile_pair.STABILITY_STABLE == "stable"
        assert mobile_pair.STABILITY_EPHEMERAL == "ephemeral"
