# Hermes Mobile

Native iOS access to a stock, self-hosted Hermes Agent gateway.

Hermes Mobile connects directly to the gateway's stock HTTP and WebSocket APIs. It does not patch Hermes core and it does not place a semantic relay in the chat path.

## Repository layout

- `apps/ios` — the iPhone app, widgets, share extension, and tests
- `plugins/hermes-mobile` — optional gateway-edge support for APNs, Live Activities, device registration, and durable submit receipts
- `server/push-relay` — optional APNs delivery service; it never owns sessions or transcripts
- `scripts/ios-build.sh` — serialized local Xcode build wrapper

The iOS app works as a foreground stock-gateway client without the optional notification components. Install those components only when background notifications or Live Activities are required.

## Build

```sh
cd apps/ios
xcodegen generate
cd ../..
scripts/ios-build.sh build \
  -scheme HermesMobile \
  -destination 'generic/platform=iOS'
```

`apps/ios/project.yml` is the Xcode project source of truth.

## Hermes upstream work

This repository contains only the Hermes Mobile product. Contributions to Hermes Agent core belong in the separate `hermes-agent-fork` repository, which continues to track `NousResearch/hermes-agent` and preserves the upstream pull-request path.

## License

See [LICENSE](LICENSE).

