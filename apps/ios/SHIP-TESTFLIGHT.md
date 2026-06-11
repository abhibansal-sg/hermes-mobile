# TestFlight ship runbook (fork-local — never in upstream-bound patches)

Everything a fresh session needs to archive + upload HermesMobile to
TestFlight. The credential FILES live at machine-global paths outside the
repo (per the API-key-scoping discipline — never commit a `.p8`); this doc
carries only the non-secret pointers and the exact commands.

## Credentials & where they live

| What | Where | Notes |
|---|---|---|
| App Store Connect API key | `~/.appstoreconnect/private_keys/AuthKey_3DHXXG4GHQ.p8` | altool's DEFAULT search path — `--apiKey` finds it with no path flag. Machine-global: every worktree/session sees it. |
| ASC key ID | `3DHXXG4GHQ` | not secret without the .p8 |
| ASC issuer ID | `d7deff8e-5489-4d18-995d-c8a10f854118` | not secret without the .p8 |
| Team | `6J4Y9NKRQ2` (paid) | bundle id `ai.hermes.app` |
| Distribution signing | "Apple Distribution" cert in the login keychain + the three "Hermes TF …" provisioning profiles (app / share / HermesWidgets) | manual signing, pinned in `ExportOptions-TestFlight.plist` |
| Export options | `apps/ios/ExportOptions-TestFlight.plist` (in-repo) | app-store-connect method, upload destination |
| APNs server key (NOT for shipping — gateway push) | `~/.hermes/apns-key.p8`, key `TQQF7DKKX8` | armed via the dashboard wrapper env |

## Ship procedure (exact commands that shipped builds 22 and 29)

Version bump first (TestFlight ship commits are the ONLY place build numbers
change): `CURRENT_PROJECT_VERSION` in `apps/ios/project.yml`, then
`cd apps/ios && xcodegen generate`.

```sh
ASC_KEY=/Users/abbhinnav/.appstoreconnect/private_keys/AuthKey_3DHXXG4GHQ.p8
ASC_ISSUER=d7deff8e-5489-4d18-995d-c8a10f854118

# 1. Archive (ALWAYS via the wedge-safe wrapper — never raw xcodebuild).
#    The ASC auth flags + -allowProvisioningUpdates let xcodebuild refresh the
#    three "Hermes TF" distribution profiles unattended.
HERMES_BUILD_TIMEOUT=2400 scripts/ios-build.sh archive \
  -scheme HermesMobile -destination 'generic/platform=iOS' \
  -archivePath /tmp/hermes-tf/HermesMobile.xcarchive \
  -authenticationKeyPath "$ASC_KEY" -authenticationKeyID 3DHXXG4GHQ \
  -authenticationKeyIssuerID "$ASC_ISSUER" -allowProvisioningUpdates

# 2. GATE: CFBundleVersion must match across app + BOTH extensions
#    (a mismatch is rejected by ASC after upload, wasting a build number).
A=/tmp/hermes-tf/HermesMobile.xcarchive/Products/Applications/HermesMobile.app
for p in "$A/Info.plist" "$A/PlugIns/HermesWidgets.appex/Info.plist" \
         "$A/PlugIns/HermesShare.appex/Info.plist"; do
  /usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$p"
done

# 3. Export — ExportOptions has destination=upload, so this step UPLOADS
#    directly to App Store Connect (no separate altool step needed).
xcodebuild -exportArchive \
  -archivePath /tmp/hermes-tf/HermesMobile.xcarchive \
  -exportOptionsPlist apps/ios/ExportOptions-TestFlight.plist \
  -exportPath /tmp/hermes-tf/export \
  -authenticationKeyPath "$ASC_KEY" -authenticationKeyID 3DHXXG4GHQ \
  -authenticationKeyIssuerID "$ASC_ISSUER" -allowProvisioningUpdates
# Success line: "Uploaded HermesMobile" + "** EXPORT SUCCEEDED **"

# 4. Poll ASC (app id 6777140135) until the build shows processingState VALID
#    (~5-15 min): GET /v1/builds?filter[app]=6777140135&sort=-uploadedDate
#    with an ES256 JWT (iss=$ASC_ISSUER, kid=3DHXXG4GHQ, aud=appstoreconnect-v1).
```

Notes: the key also exists at `~/.appstoreconnect/private/` (same file; older
sessions used that path — either works when passed explicitly). TestFlight
builds register APNs under the PRODUCTION environment
(`HERMES_APNS_USE_SANDBOX=0` on the gateway). Internal-group tester:
ab0991@gmail.com.

Uploading is a RELEASE action — get the user's go before step 3.
