# QA-3 S12 / A8 — Notification deep-link manual device proof

The unit tests pin the contract end-to-end (payload → decode → route). The final
"tap a real notification, land in the owning chat" step is a hardware-only proof
(the simulator cannot receive APNs, and the relay sandbox fan-out requires the
owner's real device token). Run it after build 117 is installed on the iPhone
Air (UDID `1D51F2FB-1DB2-52BF-818B-EFD2ACE7C0E7`).

## Preconditions

1. iPhone Air is paired relay-mode, build 117 installed, APNs registration
   healthy (`pushRegistrationHealthy == true`, relay log shows
   `push.register: device token registered over relay (…<token> device_id=…<id>)`
   with a NON-`<none>` device_id — that is the S13 fix, A9).
2. The phone is backgrounded (or on a different session) so the foreground gate
   does NOT suppress the banner.
3. At least one COMPRESSED session in the list — its runtime (live) id differs
   from its stored (origin) id. The bug only reproduces for these; an
   in-place session already had `session_id == stored_session_id`.

## Steps

1. From the Mac (or a second client) drive a turn on the compressed session so
   it completes while the phone is backgrounded — the relay's `Notifier._fire`
   composes a `turn_complete` push with `stored_session_id` set
   (`relay/hermes_relay/notifier.py:_fire`, after the S12 fix).
2. Wait for the banner on the phone ("Hermes finished: …").
3. Tap the banner.

## Pass

The phone opens DIRECTLY into the chat for that compressed session — the
`RoutePushTap(.turnComplete(sessionId: live, storedSessionId: origin))`
→ `openForPush(storedSessionId: origin)` path resolves to the stored id and
`SessionStore.open(summary)` lands in the chat. The Inbox must NOT surface.

Capture: a screenshot of the open chat + the relay log line showing the
`stored_session_id` in the fan-out payload (masked-token evidence file under
`/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver-qa3/pushpolish/`).

## Fail (the bug we fixed)

Before the fix: the banner's payload carried only the runtime `session_id`;
`SessionStore.open` is keyed by the stored id; the inbox's runtime→stored map
was empty for an ordinary (non-attention) `turn_complete`; both lookups missed;
the phone dumped to the Inbox.

## Unit-test coverage backing this proof

- `NotificationActionTests.testDecodeTapCarriesStoredSessionIdWhenPresent` —
  payload → Tap decodes both ids.
- `NotificationActionTests.testDecodeTapBlankStoredSessionIdTreatedAsNil` —
  whitespace id does not poison routing.
- `PushTapRoutingTests.testTapWithStoredSessionIdOpensOwningSessionDirectly` —
  warm path opens the stored-id session synchronously, no Inbox dump, even
  when the runtime id is NOT in the inbox map (the precondition that was broken).
- `PushTapRoutingTests.testTapWithStoredSessionIdColdOpensAfterRefresh` —
  cold path refreshes then opens via the stored id.
- relay `test_notifier.test_payload_carries_stored_session_id_for_compressed_session`
  + `test_gateway_client.test_origin_id_for_resolves_live_back_to_origin`.
