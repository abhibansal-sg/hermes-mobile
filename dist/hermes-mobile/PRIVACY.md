# Privacy Policy — Hermes Agent (HermesMobile)

_Last updated: June 2026_

Hermes Agent ("the app") is an open-source iOS client for a **self‑hosted
`hermes-agent` gateway that you run yourself**. This policy explains what the app
does — and does not do — with your data.

## The short version

The app talks **only to the gateway you configure** (your own machine). There is
no HermesMobile cloud service, no analytics, no third‑party servers, and no
account with us. The publisher does **not** collect, receive, store, or have any
access to your data.

## What the app stores on your device

- **Connection details** — your gateway URL and pairing token — stored in the iOS
  **Keychain** on your device, used solely to connect to your gateway.
- **A local cache** of your sessions and messages so the app loads quickly and
  works offline. It lives on your device and is removed when you delete the app.
- **Notification / device tokens** (only if you enable notifications) are
  registered with **your** gateway so it can send you push. Push is delivered via
  Apple's APNs using your gateway's signing key.

## What we collect

**Nothing.** The publisher operates no servers and receives no data from the app.
All conversation content, files, and activity flow exclusively between your device
and your own gateway.

## Third parties

- **Apple** processes push notifications via APNs and provides TestFlight
  distribution, subject to Apple's own privacy policy.
- The app integrates **no** other third‑party SDKs, trackers, or analytics.

## Your control

Because everything lives on your device and your gateway, you control it. Delete
the app to remove its local cache and Keychain entries; manage history on your own
gateway.

## Children

The app is not directed at children under 13.

## Changes

Updates to this policy are posted in the project repository:
https://github.com/ab0991-oss/hermes-ios

## Contact

Questions: open an issue at https://github.com/ab0991-oss/hermes-ios/issues
