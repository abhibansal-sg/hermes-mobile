# Transparent stock-proxy gate

The Python phone driver sends stock Hermes JSON-RPC frames through the real
relay to an isolated scripted gateway. The relay must forward WebSocket text and
HTTP bodies without parsing, translating, storing, or reframing them.

Run:

```bash
tests/e2e_daily_driver/run_gate.sh
```

The default test uses an OS-assigned gateway port and relay port. It never
touches the live gateway on 9119 or the live relay on 8788. An optional second
test can target an explicitly configured isolated stock gateway on port 9130+
using `ABH519_STOCK_PROXY_WS`, `ABH519_STOCK_PROXY_HTTP`, and
`ABH519_STOCK_PROXY_TOKEN_FILE`.
