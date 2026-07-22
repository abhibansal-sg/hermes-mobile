# ABH-519 Phase 0 physical-device logging evidence

**Captured:** 2026-07-22 17:28–17:29 +08:00

**Source:** physical iPhone Air (`iPhone18,4`), UDID
`1D51F2FB-1DB2-52BF-818B-EFD2ACE7C0E7`

**App:** `ai.hermes.app`, version `1.0.1`, build `120`

**Source commit:** `f98610f9f9eb7dc85c017eaa3165a005dbdab958`

## Result

The physical-device logging channel is pullable and does not depend on simulator stdout or
`idevicesyslog`. The existing DEBUG-only `PerfHitchLogger` writes the same notice it sends to
`os.Logger` into the app container at `tmp/hermes-perf.log`. After launching the installed app
with `HERMES_PERF_LOG=1`, `devicectl` pulled that file from the iPhone Air. Its first captured
signpost was:

```text
PERF logger started (HERMES_PERF_LOG=1)
```

The pulled file was 975 bytes at `2026-07-22 17:29:09 +0800`; SHA-256:
`f784f8d7d49ddb55259872b606c78b6a3e92cb183118dfbdf6044105aa04e2d1`.
It also contained subsequent two-second physical-display windows, proving that the line came from
the running device process rather than the build host.

## Reproduction record

The app was built only through the repository mutex wrapper:

```sh
HERMES_BUILD_TIMEOUT=2400 \
HERMES_BUILD_LOG=/tmp/abh519-phase0-device-build.log \
scripts/ios-build.sh build \
  -scheme HermesMobile -configuration Debug \
  -destination 'platform=iOS,id=1D51F2FB-1DB2-52BF-818B-EFD2ACE7C0E7' \
  -allowProvisioningUpdates
```

Result: `** BUILD SUCCEEDED **`. The product was installed from this worktree's
`apps/ios/.derivedData/Build/Products/Debug-iphoneos/HermesMobile.app`; device inventory then
reported:

```text
Hermes Agent   ai.hermes.app   1.0.1   120
```

The capture used only existing app code:

```sh
xcrun devicectl device process launch \
  --device 1D51F2FB-1DB2-52BF-818B-EFD2ACE7C0E7 \
  --terminate-existing \
  --environment-variables '{"HERMES_PERF_LOG":"1"}' \
  ai.hermes.app

xcrun devicectl device copy from \
  --device 1D51F2FB-1DB2-52BF-818B-EFD2ACE7C0E7 \
  --domain-type appDataContainer --domain-identifier ai.hermes.app \
  --source tmp/hermes-perf.log \
  --destination /tmp/abh519-phase0-hermes-perf.log
```

After capture, the app was terminated and relaunched normally without `HERMES_PERF_LOG`, so no
diagnostic display-link logger was left running. No Swift, relay, gateway, database, or live-service
code/configuration was changed for this evidence.

## Channel decision for later physical gates

Use a pullable, sanitized app-container evidence file for release-gate markers when unattended
capture is required. `os.Logger` remains useful in Console with Info/Debug enabled, but this pull
path is scriptable, attributable to the physical device, and does not need root access to
`log collect`. Never place credentials, prompt contents, or secure-request values in the file.
