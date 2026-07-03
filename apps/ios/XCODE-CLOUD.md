# Xcode Cloud — Operator Guide for HermesMobile

> **OPTION-1 SHIP MODE (2026-07-03, active plan):** Xcode Cloud's job here is the
> SHIP archive+upload (the 40-min build that wedges the Mac). Verifier builds stay
> local. Create the **"HermesMobile Ship"** workflow below FIRST — the CI/test
> workflow from the original guide is optional and can wait.

## The 5-minute connect (Abhi's one-time step)

1. Open Xcode → **Integrate** menu → **Get Started** (or ⌘9 → Cloud tab → +).
2. Sign in with your Apple ID (a.b.0991@gmail.com) when prompted.
3. Select the **HermesMobile** app target.
4. **Grant Access on GitHub** → authorize for **abhibansal-sg** → confirm
   `abhibansal-sg/hermes-mobile` is listed (repo moved from ab0991-oss).
5. Xcode Cloud drafts a workflow — replace it with "HermesMobile Ship" below.

## The Ship workflow (the one that matters)

App Store Connect → Xcode Cloud → Manage Workflows → **+**:

| Setting | Value |
|---|---|
| Name | `HermesMobile Ship` |
| Start condition | **Branch Changes** → branch `environment-and-workflows-overview`, **Files touched: apps/ios/project.yml** (the ship script's build-number bump commit is what triggers it) |
| Environment | Latest Xcode, latest macOS |
| Action | **Archive** — platform iOS, scheme `HermesMobile`, deployment prep: **TestFlight (Internal Only)** |
| Post-action | **TestFlight Internal Testing** → group: Abhi's internal group |
| Signing | Cloud-managed (accept the default) |

`ci_post_clone.sh` (already in this directory) regenerates the xcodeproj from
project.yml on the Cloud VM — no generated project needs committing.

## After the connect: hand the workflow id to the loop

```sh
node apps/ios/ci_scripts/asc-cloud.mjs list-workflows   # grab the Ship workflow UUID
```
Then in `.claude/loops/governor.json` → `ship_policy.xcode_cloud`: set
`workflow_id` and `active: true`. From the next cadence ship onward,
`ship-testflight.sh` pushes the build bump, triggers the cloud run, and waits —
the Mac never archives. Any cloud failure automatically falls back to the local
wedge-safe path, so shipping never stalls on Apple's queue.

---

## 0. What is connected + what it costs

| Thing | Detail |
|---|---|
| Repo | `abhibansal-sg/hermes-mobile` on GitHub |
| Scheme | `HermesMobile` (defined in `apps/ios/project.yml`) |
| Xcode project path | `apps/ios/HermesMobile.xcodeproj` |
| Free compute | **25 compute hours/month** on the Apple Developer account |
| Paid overage | **$49.99 / 100 compute hours** (charged to the dev account) |
| Approx. cost per PR build | ~8–12 min = ~0.15 h; ~160 PR builds fit in the free tier |

---

## 1. One-time setup: connect the GitHub repo

> Do this once. Takes ~5 min.

1. Open **Xcode → Integrate** menu (or open the Xcode Cloud tab in the Report Navigator, ⌘9).
2. Click **Get Started** (if first time) or the **+** button to add a product.
3. Xcode will prompt you to sign in to App Store Connect with your Apple ID (`a.b.0991@gmail.com`).
4. Select the **HermesMobile** app target in the project selector.
5. Xcode Cloud will ask you to **grant access to your source code provider**:
   - Click **Grant Access on GitHub**.
   - GitHub opens in your browser. Click **Install & Authorize** for the `abhibansal-sg` account.
   - GitHub redirects back to App Store Connect. Confirm you see `abhibansal-sg/hermes-mobile` listed.
6. Back in Xcode, the repo picker now shows `abhibansal-sg/hermes-mobile`. Select it.
7. Xcode Cloud generates a first draft workflow. **Do not use it** — you will replace it with the configuration in Step 2.

---

## 2. Create the CI workflow

In App Store Connect → **Xcode Cloud** → your product → **Manage Workflows** → **+**:

### Workflow name
`HermesMobile CI`

### Start Condition (trigger)
Add two triggers:

| Trigger | Settings |
|---|---|
| **Pull Request** | Branch changes: `phase2-upstream-rebase` (source) → any base; check **"Changes to Files"** if you want to restrict to `apps/ios/**` |
| **Branch** | Branch: `phase2-upstream-rebase`; also add `main` when it exists |

### Actions — Add in order:

#### Action 1: Build
- Type: **Build**
- Platform: **iOS**
- Scheme: **HermesMobile**
- Configuration: **Debug** (for PR builds)
- Xcode version: **Latest Release**

#### Action 2: Test
- Type: **Test**
- Platform: **iOS Simulator**
- Scheme: **HermesMobile**
- Simulator: **iPhone 16** (or any latest) — use **Latest iOS** version
- **Pre-xcodebuild script**: `apps/ios/ci_scripts/ci_pre_xcodebuild.sh`
  - In the action editor, click **Add Pre-action** → Custom Script → path above
- Tests to run: all (default); gateway-dependent tests auto-skip if the gateway env vars are absent

#### Action 3 (post-action): Archive + TestFlight  *(tag/release builds only)*
- Add a **Post-build** action of type **TestFlight (Internal Testing)**
- Add a **Start Condition**: only when the current branch matches `release/*` or a tag matches `v*`
- Signing: **Xcode Managed Profile** (see Step 3)

### Archive Settings (for Action 3)
- Deployment: **TestFlight & App Store**
- Export method: **App Store Connect**

---

## 3. Code signing — cloud-managed

In the workflow editor, under **Archive** action → **Signing**:

1. Select **Xcode Cloud Managed Distribution** (Apple manages the certificate and provisioning profile).
2. Ensure the **Bundle ID** `ai.hermes.app` is registered in App Store Connect → Identifiers. If not, create it now (Certificates, IDs & Profiles → Identifiers → **+** → App ID → `ai.hermes.app`).
3. Xcode Cloud will auto-create and rotate the signing certificate. You do not need to touch your local keychain.

> **Note:** The entitlements file at `apps/ios/Entitlements/HermesMobile.entitlements` must match the capabilities registered for the App ID. Check App Groups, Push Notifications, etc. if the archive action fails with a signing error.

---

## 4. Environment variables and secrets

In **App Store Connect → Xcode Cloud → Manage Workflows → Environment Variables**:

| Variable name | Value | Secret? | Required for |
|---|---|---|---|
| `HERMES_CI_TOKEN` | A fixed bearer token (generate with `python3 -c "import secrets; print(secrets.token_urlsafe(32))"`) | **YES (Secret)** | CrossClientSyncUITests, RemoteURLModeUITests |
| `HERMES_CI_MODEL_KEY` | Your Anthropic API key (or leave blank if live LLM calls are not needed in CI) | **YES (Secret)** | Gateway model calls in UI tests |

**How to add a secret variable:**
1. In the workflow editor click **Environment Variables** → **+**.
2. Enter the name, paste the value, check **Secret**.
3. Click **Save**.

> Secrets are injected into the build VM at runtime. They are never stored in the repo. The `ci_pre_xcodebuild.sh` script reads `HERMES_CI_TOKEN` and `HERMES_CI_MODEL_KEY` from the environment — if absent, gateway-dependent tests XCTSkip and the build stays green.

---

## 5. Verify the workflow is wired correctly

After saving the workflow:

1. Open a draft PR targeting `phase2-upstream-rebase` (or push a commit to that branch).
2. In **App Store Connect → Xcode Cloud → Builds**, you should see a new build appear within ~30 s.
3. Click the build to view the log stream. You will see:
   - `[ci_post_clone] xcodegen generate succeeded.` — confirms project regeneration
   - `[ci_post_clone] SPM resolution complete.` — confirms dependencies resolved
   - If `HERMES_CI_TOKEN` is set: `[ci_pre_xcodebuild] /health OK` — gateway running
4. The Test action results will show which tests ran vs. skipped.

---

## 6. ci_scripts file reference

| File | Xcode Cloud lifecycle hook | Purpose |
|---|---|---|
| `apps/ios/ci_scripts/ci_post_clone.sh` | **Post-clone** (automatic) | Install xcodegen, regenerate project, resolve SPM |
| `apps/ios/ci_scripts/ci_pre_xcodebuild.sh` | **Pre-xcodebuild** (manual, Test action only) | Start isolated gateway on :9123, export `TEST_RUNNER_HERMES_URL/TOKEN` |

Xcode Cloud automatically discovers `ci_post_clone.sh` because it is named exactly that and lives in `ci_scripts/` adjacent to the `.xcodeproj`. The pre-xcodebuild script must be wired manually in the workflow editor (Step 2, Action 2).

---

## 7. What the user must do vs. what is already done

| Done (committed) | User-only |
|---|---|
| `ci_post_clone.sh` authored, shell-checked, executable | Connect GitHub repo in App Store Connect (Step 1) |
| `ci_pre_xcodebuild.sh` authored, shell-checked, executable | Create workflow in App Store Connect (Step 2) |
| `project.yml` is the xcodegen source of truth | Set `HERMES_CI_TOKEN` + `HERMES_CI_MODEL_KEY` as secret env vars (Step 4) |
| Scheme env var substitution already wired (`$(TEST_RUNNER_HERMES_URL)`) | Trigger a first build to confirm green |
| Gateway-dependent tests XCTSkip gracefully when creds are absent | (Optional) Set up archive/TestFlight action for tag builds |

---

## 8. Troubleshooting

**`xcodegen: command not found`**
Homebrew is not in PATH on the CI VM. The script uses `brew install xcodegen`; if brew itself fails, check the Xcode version selected in the workflow (older Xcode images may have a stale Homebrew).

**`project.yml not found`**
The workflow's "Xcode project" setting points to the wrong directory. Set it to `apps/ios/HermesMobile.xcodeproj` — Xcode Cloud then runs ci scripts from `apps/ios/ci_scripts/`.

**Gateway-dependent tests always skip**
`HERMES_CI_TOKEN` is not set or is set on the wrong workflow/action. Check App Store Connect → Manage Workflows → Environment Variables.

**Gateway /health timeout**
The `[web]` extras in `pyproject.toml` may not install. Check the ci_pre_xcodebuild log for pip errors. As a fallback, add `fastapi uvicorn` to the pip install line explicitly (already done in the script).

**Archive signing fails**
Verify the bundle ID `ai.hermes.app` exists in App Store Connect → Identifiers, and that all entitlements (App Groups, etc.) declared in `Entitlements/HermesMobile.entitlements` are enabled for that identifier.
