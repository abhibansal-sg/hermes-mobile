# asc-cloud.mjs — Xcode Cloud programmatic driver

A zero-dependency Node ESM script that drives Xcode Cloud builds via the
App Store Connect REST API. No GUI, no Xcode needed — pure API calls.

## Prerequisites

- Node 18+ (uses native `fetch` and `crypto`)
- A valid `.p8` API key at one of the default locations (see below)

## Key resolution (no secret in the repo)

The script reads the private key **only at runtime**, in this order:

1. `$ASC_KEY_PATH` (env override — absolute path to any `.p8`)
2. `~/.appstoreconnect/private_keys/AuthKey_3DHXXG4GHQ.p8`
3. `~/.appstoreconnect/private/AuthKey_3DHXXG4GHQ.p8`

The key ID (`3DHXXG4GHQ`), issuer ID, and app ID are hardcoded as defaults
but all three can be overridden via env vars (`ASC_KEY_ID`, `ASC_ISSUER_ID`,
`ASC_APP_ID`).

## Subcommands

### `list-workflows`
Lists all Xcode Cloud workflows for the app with their IDs and names.
Use this to discover workflow IDs before triggering builds.

```sh
node apps/ios/ci_scripts/asc-cloud.mjs list-workflows
```

### `trigger <workflowId> <gitRef>`
Starts a new cloud build run. `gitRef` can be a bare branch name
(`phase2-upstream-rebase`) or a full ref (`refs/heads/phase2-upstream-rebase`).

```sh
node apps/ios/ci_scripts/asc-cloud.mjs trigger <workflowId> phase2-upstream-rebase
```

Prints the new `buildRunId`. Pipe it into `wait` or `status`.

### `status <buildRunId>`
Prints the current execution progress, completion status, and per-action
issue counts (errors / warnings / test failures).

```sh
node apps/ios/ci_scripts/asc-cloud.mjs status <buildRunId>
```

### `wait <buildRunId>`
Polls every 60 seconds until `executionProgress == COMPLETE`.
- Exit 0 → `SUCCEEDED`
- Exit 1 → `FAILED` / `ERRORED` / `CANCELED`
- Exit 2 → 45-minute timeout

```sh
node apps/ios/ci_scripts/asc-cloud.mjs wait <buildRunId>
```

### `issues <buildRunId>`
For each action in the build run, fetches the issue list from the API and
prints all `TEST_FAILURE` messages with file references, plus a warning count.

```sh
node apps/ios/ci_scripts/asc-cloud.mjs issues <buildRunId>
```

## Typical CI loop

```sh
# 1. Find the workflow ID (one-time)
node apps/ios/ci_scripts/asc-cloud.mjs list-workflows

# 2. Trigger a build
RUN_ID=$(node apps/ios/ci_scripts/asc-cloud.mjs trigger <wfId> phase2-upstream-rebase \
  | grep "^  ID:" | awk '{print $2}')

# 3. Wait for completion
node apps/ios/ci_scripts/asc-cloud.mjs wait "$RUN_ID"

# 4. If non-zero exit, inspect failures
node apps/ios/ci_scripts/asc-cloud.mjs issues "$RUN_ID"
```

## JWT details

Each API call mints a fresh ES256 JWT (header `{alg:ES256, kid, typ:JWT}`,
payload `{iss, iat, exp:iat+1100, aud:'appstoreconnect-v1'}`). Re-minting
per request ensures long-running `wait` loops never hit a 401 from token
expiry. The signature uses `crypto.sign('SHA256', …, {dsaEncoding:'ieee-p1363'})`
to produce the IEEE P1363 format (`r‖s`, 64 bytes) that App Store Connect
requires — not the DER format that OpenSSL emits by default.

## Error handling

- Transient `5xx` / `429` responses are retried up to 3 times with
  exponential back-off (5 s, 10 s).
- `wait` continues polling on any single-poll error rather than aborting.
- The 45-minute ceiling prevents runaway polling on hung builds.
