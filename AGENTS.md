# Hermes Mobile development rules

- The Hermes gateway is strictly stock. Do not patch `hermes-agent` core from this repository.
- The iOS app connects directly to stock HTTP and WebSocket endpoints.
- The optional plugin may adapt gateway lifecycle events to mobile notifications, device registration, and durable receipts. It must not own chat sessions, transcripts, model execution, or a second transport protocol.
- Reuse the existing `HermesGatewayClient`, `WorkRepository`, `CacheStore`, and `ConnectionStore`. Do not add a second store or coordinator for the same responsibility.
- Prefer deletion and correction of existing ownership/wiring over compatibility branches.
- `apps/ios/project.yml` is authoritative. Regenerate the Xcode project with `xcodegen` after changing it.
- Use `scripts/ios-build.sh` for local Xcode builds. Never run concurrent `xcodebuild` processes.
- Keep secrets and signing material outside the repository.

