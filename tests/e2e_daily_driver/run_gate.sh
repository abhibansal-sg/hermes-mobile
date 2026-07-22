#!/usr/bin/env bash
# Transparent stock-protocol relay gate. Never targets the live 9119 gateway.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

cd "$ROOT"
exec uv run --project relay --extra dev pytest \
  -c relay/pyproject.toml \
  --confcutdir=tests/e2e_daily_driver \
  tests/e2e_daily_driver/test_k_stock_transparent_proxy.py "$@"
