#!/usr/bin/env python3
"""QA-3 S13 / A9 relay convergence evidence (no APNs send).

Replays the exact build-116 forensics scenario through the REAL reused
push_engine.register_token under an isolated HERMES_HOME and proves the
registry converges to exactly one phone entry (sandbox, non-null device_id)
after build 117's first registration. The fan-out recipient count drops from
3 to 1.

No network, no APNs, no live gateway. Safe to run anywhere.

Usage:
    python3 scripts/qa3_s13_convergence_proof.py [tmp_hermes_home]

Writes a masked evidence summary to stdout. Redirect to a file for the
evidence bundle.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path


def _mask(token: str) -> str:
    return "…" + token[-6:] if token else "<none>"


def main() -> int:
    # The forensics tokens (masked last-6 in the relay-log evidence); shaped
    # as valid 64-hex APNs tokens so push_engine normalizes+accepts them.
    stale_prod_a = "1" * 64
    stale_prod_b = "2" * 64
    stale_sandbox = "3" * 64
    phone_token_117 = "e" * 64

    tmp_home = Path(sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="qa3-s13-"))
    os.environ["HERMES_HOME"] = str(tmp_home)
    # Import push_engine through the relay's plugin_bridge so the flat
    # `from utils import atomic_json_write` inside it resolves correctly
    # (the same path the relay uses at runtime).
    sys.path.insert(0, str(Path("relay").resolve()))
    from hermes_relay import plugin_bridge  # type: ignore
    pn = plugin_bridge.import_push_engine()

    registry = tmp_home / "push_tokens.json"
    registry.write_text(json.dumps([
        {"token": stale_prod_a, "platform": "ios", "env": "production"},
        {"token": stale_prod_b, "platform": "ios", "env": "production"},
        {"token": stale_sandbox, "platform": "ios", "env": "sandbox"},
    ]))

    print(f"# QA-3 S13 convergence proof — HERMES_HOME={tmp_home}")
    print(f"# build-116 registry (3 null-device_id rows, masked):")
    for e in pn.registry_entries():
        print(f"#   env={e.get('env'):<10} device_id={e.get('device_id')!s:<10} token={_mask(e['token'])}")

    fanout_before = pn.registered_tokens()
    print(f"# fan-out recipients BEFORE 117 register: {len(fanout_before)}")

    # Build 117 registers with a real per-install device id (the iOS S13 fix).
    ok = pn.register_token(
        phone_token_117, platform="ios", env="sandbox", device_id="phone-install-qa3"
    )
    assert ok, "register_token returned False"

    entries = pn.registry_entries()
    fanout_after = pn.registered_tokens()
    print(f"# AFTER 117 register (device_id=…qa3):")
    for e in entries:
        print(f"#   env={e.get('env'):<10} device_id={e.get('device_id')!s:<18} token={_mask(e['token'])}")
    print(f"# fan-out recipients AFTER  117 register: {len(fanout_after)}")

    null_id_survivors = [e for e in entries if not e.get("device_id")]
    print(f"# null-device_id survivors: {len(null_id_survivors)}")

    # Contract (A9): registry == exactly 1 phone entry, sandbox, non-null device_id;
    # fan-out posts to 1 token.
    assert len(entries) == 1, f"expected 1 entry, got {len(entries)}"
    assert entries[0]["device_id"] == "phone-install-qa3"
    assert entries[0]["env"] == "sandbox"
    assert len(fanout_after) == 1
    assert len(null_id_survivors) == 0
    print("# PASS: registry converged to 1 sandbox non-null-device_id entry; fan-out = 1 token.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
