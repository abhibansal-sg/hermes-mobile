"""Aggregate per-scenario verdicts from a soak run dir into one SUMMARY.json.

Run after a soak: ``python summarize.py <run_dir>`` (run_soak.sh does this). It
walks the run dir for every ``verdict.json``, rolls them up into a pass/fail
table per scenario + per invariant, and writes ``SUMMARY.json`` alongside them.
Also prints a compact table to stdout.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def summarize(run_dir: Path) -> dict:
    verdicts = sorted(run_dir.glob("*/verdict.json"))
    rows = []
    all_ok = True
    for vp in verdicts:
        try:
            v = json.loads(vp.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            rows.append({"scenario": vp.parent.name, "ok": False,
                         "error": f"unreadable verdict: {exc}"})
            all_ok = False
            continue
        inv = v.get("invariants", {})
        inv_ok = {name: bool(r.get("ok", True)) for name, r in inv.items()}
        violations = []
        for r in inv.values():
            violations.extend(r.get("violations") or [])
        ok = bool(v.get("ok", True))
        all_ok = all_ok and ok
        rows.append({
            "scenario": v.get("scenario", vp.parent.name),
            "ok": ok,
            "invariants": inv_ok,
            "violations": violations[:10],
            "n_violations": len(violations),
        })

    summary = {
        "run_dir": str(run_dir),
        "scenarios_run": len(rows),
        "all_ok": all_ok,
        "results": rows,
    }
    (run_dir / "SUMMARY.json").write_text(
        json.dumps(summary, indent=2, default=str), encoding="utf-8")

    # Compact table.
    print(f"\n{'SCENARIO':28} {'OK':4} INVARIANTS")
    print("-" * 72)
    for r in rows:
        inv = r.get("invariants", {})
        inv_str = " ".join(f"{k}:{'✓' if ok else '✗'}" for k, ok in sorted(inv.items()))
        print(f"{r['scenario']:28} {'PASS' if r['ok'] else 'FAIL':4} {inv_str}")
        if r.get("violations"):
            for vio in r["violations"][:3]:
                print(f"    ! {vio}")
    print("-" * 72)
    print(f"scenarios_run={len(rows)} all_ok={all_ok}")
    print(f"SUMMARY.json -> {run_dir / 'SUMMARY.json'}")
    return summary


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: summarize.py <run_dir>", file=sys.stderr)
        return 2
    run_dir = Path(sys.argv[1])
    if not run_dir.is_dir():
        print(f"not a dir: {run_dir}", file=sys.stderr)
        return 2
    summary = summarize(run_dir)
    return 0 if summary["all_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
