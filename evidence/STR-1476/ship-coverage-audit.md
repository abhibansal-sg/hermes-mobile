# STR-1476 ship coverage audit

Date: 2026-07-11
Base: `origin/environment-and-workflows-overview`
Head before this record: `10cc554ef`

## Changed behavior and coverage

| Behavior | Implementation | Coverage |
| --- | --- | --- |
| A cached or saved valid connection may render the chat shell during `.needsSetup` | `ConnectionStore.swift` | `CacheFirstLaunchTests` focused suite, 11/11 passing |
| A failed configure without persisted credentials remains on onboarding | Existing closed gate retained | `CacheFirstLaunchTests` negative-path assertions |
| iPad CUJ uses an isolated paired-state launch path | `cuj-01-launch-drawer-ipad.yaml` | Dedicated iPad CUJ fixture |
| iPhone CUJ remains on its original launch path | `cuj-01-launch-drawer.yaml` | Existing CUJ retained with persistence wait |
| Duplicate provider helper no longer blocks iOS compilation | `RestClient+Providers.swift` | `scripts/verify.sh` iOS build gate passed |

## Gate result

- Focused iOS regression suite: 11 passed, 0 failed.
- Full `scripts/verify.sh`: all relevant build/typecheck/test gates passed except three `ui-tui` assertions.
- The same three `ui-tui` failures reproduce on the base branch and the PR does not touch `ui-tui`; see `verify-final.md`.

Coverage verdict: sufficient for the changed behavior. No uncovered changed branch was identified.
