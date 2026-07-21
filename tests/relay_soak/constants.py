"""Shared constants for the relay soak harness.

PORT DISCIPLINE (spec hard rules — binding):

* The LIVE gateway (9119) and LIVE relay (8788) are NEVER touched by this track
  — not even a health curl. Every gateway/relay this harness runs is isolated.
* Ports 9130-9139 are RESERVED for the QA-3 swarm (which shares this machine) —
  this harness never binds them.
* Real gateway/relay PROCESSES this harness forks bind the isolated band
  9140-9160. The in-process deterministic mock gateway uses OS-assigned
  ephemeral loopback ports (49152+), which can never collide with any of the
  reserved bands above.

All temp state (HERMES_HOME, durable relay state, evidence) lives on
/Volumes/MainData — the internal disk is tight (storage policy).
"""

from __future__ import annotations

from pathlib import Path

# --- evidence --------------------------------------------------------------
EVIDENCE_ROOT = Path("/Volumes/MainData/Developer/hermes-tmp/evidence/relay-soak")

# --- isolated port band ----------------------------------------------------
# Real subprocess gateways/relays allocate from here. 9130-9139 (QA-3) and
# 9119/8788 (live) are deliberately excluded.
ISOLATED_PORT_BASE = 9140
ISOLATED_PORT_MAX = 9160

# Reserved bands we must NEVER bind (defensive guard in the allocator).
FORBIDDEN_PORTS = frozenset({9119, 8788}) | frozenset(range(9130, 9140))

# --- the ratified protocol token the mock gateway accepts ------------------
# Identical to tests/e2e_daily_driver/mock_gateway/server.py E2E_TOKEN — the
# loopback-only credential that gates the isolated test traffic. NEVER a real
# gateway credential.
MOCK_GATEWAY_TOKEN = "e2e-mock-gateway-token-fixed"


def assert_isolated_port(port: int) -> None:
    """Raise if ``port`` is in a forbidden band (live or QA-3)."""
    if port in FORBIDDEN_PORTS:
        raise ValueError(
            f"refusing to use port {port}: it is in a live/QA-3 reserved band "
            f"(live 9119/8788, QA-3 9130-9139). Soak uses 9140-9160 only."
        )
