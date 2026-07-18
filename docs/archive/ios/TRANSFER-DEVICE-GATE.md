# Background transfer physical-device gate

Required before release (simulators cannot prove background relaunch delivery):

1. Install a Release build on a physical iPhone and connect it to a gateway.
2. Start an attachment upload of at least 250 MB through a throttled network.
3. Lock the phone for 60 seconds, reopen Hermes, and verify the upload finishes once.
4. Repeat, swiping Hermes away only after the task is handed to the background
   session; relaunch after completion and verify the attachment is present once,
   the owner job wakes once, and the transfer row is `completed`.
5. Repeat with airplane mode, cancellation, a revoked credential (401), and a
   removed staged file. Verify `retry_waiting`, `cancelled`, `unauthorized`, and
   `missing_file` respectively, and inspect logs/SQLite to confirm no credential
   value is present.

Record device model, iOS version, gateway revision, result, and timestamp in the
release checklist. This is a manual/XCTest physical-device gate and is not waived
by simulator unit tests.
