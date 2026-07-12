# STR-1476 cache-first launch verification

Date: 2026-07-11
Branch: `release/str-1476-str-1450-land`
Base merged before run: `origin/environment-and-workflows-overview`

## Command

```sh
scripts/ios-build.sh test \
  -scheme HermesMobile \
  -destination 'platform=iOS Simulator,id=5564C502-D7DF-4848-B7E1-9EAFF42D2925' \
  -only-testing:HermesMobileTests/CacheFirstLaunchTests
```

## Result

```text
Test Suite 'CacheFirstLaunchTests' passed at 2026-07-11 15:31:55.472.
Executed 11 tests, with 0 failures (0 unexpected) in 1.051 (1.054) seconds
** TEST SUCCEEDED **
```

The run used the required single-flight `scripts/ios-build.sh` wrapper. The wrapper exited 0 and released its machine-wide build lock.
