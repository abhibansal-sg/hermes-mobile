---
name: User location and timezone
description: User is back in Singapore at the Mac Studio (as of 2026-06-07); was previously traveling in Dar es Salaam.
type: user
originSessionId: 247467c5-73b8-4f37-81f3-a0f202fdaeca
---
User is physically at the Mac Studio M4 Max 36GB in Singapore (confirmed 2026-06-07 — "now im at the mac physically"; both iPhones visible via local CoreDevice). Previously traveling in Dar es Salaam, Tanzania (2026-04-11 → ~June 2026), during which the Mac was accessed via SSH and the iPhone was unreachable for devicectl installs.

Implication: direct dev builds to phone are possible again (`xcodebuild` + `devicectl device install`) — no TestFlight round-trip needed for iteration. Two paired devices: iPhone Air `1D51F2FB-1DB2-52BF-818B-EFD2ACE7C0E7` (hardware id `00008150-000911CA0240401C`, dogfood phone) and iPhone 16 Pro Max `07EE6E1F-3258-5E27-8167-C7CF8842E62D`.
