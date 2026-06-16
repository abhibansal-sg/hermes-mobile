# External TestFlight beta — setup + copy (ready to execute)

Everything needed to flip HermesMobile from internal to a **public external
TestFlight beta** for self-hosters. App: "Hermes Agent" (id 6777140135, bundle
`ai.hermes.app`). Build to use: the latest VALID build that's been device-verified
(49, or 50 if we ship the a11y polish first).

## Prereqs (before submitting for review)
- [ ] The candidate build is **device-verified**: you can enable + receive
      notifications, Live Activity shows on the lock screen, basic chat works.
- [ ] The **public repo is live** and `dist/hermes-mobile/install.sh` is reachable
      there (the magic-prompt + README point at it).
- [ ] `PUBLIC-README.md` placeholders filled: `<REPO_OWNER>/<REPO_NAME>`,
      `<TESTFLIGHT_PUBLIC_LINK>` (you get the link AFTER step 5), `<SUPPORT_CONTACT>`.

## App Store Connect steps (TestFlight tab)
1. **Test Information** (one-time): set the **Beta App Description**, **Feedback
   Email**, **Privacy Policy URL** (required for external testing), and confirm
   **Export Compliance** — the app already sets `ITSAppUsesNonExemptEncryption:
   false`, so it's "no" (standard TLS only).
2. **Create an External group**: TestFlight → Groups → "+" → e.g. "Public Beta".
3. **Add the build**: assign the candidate build to that group. Adding a build to
   an *external* group triggers **Beta App Review** (Apple, ~1 day, lighter than
   App Review).
4. **What to Test** (per build, see copy below).
5. After approval: open the group → **Enable Public Link** → copy the URL → put it
   in `PUBLIC-README.md` as `<TESTFLIGHT_PUBLIC_LINK>` and share it.

> Note: an external public link can be capped (max testers) and toggled off
> anytime. Internal testing (your own devices) needs no review and keeps working.

---

## Beta App Description (paste into Test Information)

> Hermes Agent puts your self-hosted Hermes agent on your iPhone — live chat,
> approvals, push notifications, and Live Activities, talking only to the gateway
> you run. Requires your own hermes-agent gateway with the HermesMobile plugin
> (setup guide: <REPO link>). No third-party servers.

## What to Test (paste per build)

> You'll need your own hermes-agent gateway with the HermesMobile plugin — see the
> setup guide (it includes a copy-paste prompt your agent can run): <REPO link>.
>
> Please try:
> • Pairing: scan the QR from `hermes mobile-pair`, or enter URL + token manually.
> • Chat: send messages, watch live streaming, switch sessions in the drawer.
> • Desktop ↔ phone: a session you touch on desktop should appear + stay in sync
>   (note: the desktop must share the same gateway — see Known Issues).
> • Notifications: Settings → Notifications → enable → grant permission. Then
>   trigger an approval or a long turn and confirm the push arrives + tapping it
>   opens the right session.
> • Live Activity: start a turn, lock the phone — the lock screen / Dynamic Island
>   should show it running.
> • Larger Text (Settings → Accessibility → Display & Text Size): the app should
>   scale, not clip.
>
> Known issues are listed in the repo's KNOWN-ISSUES. Send feedback via TestFlight
> (screenshot + "send beta feedback").

---

## Doing it via API (optional)
The ASC API (the same `.p8` used for upload) can create beta groups, assign
builds, set `publicLinkEnabled`, and create beta-review submissions
(`/v1/betaGroups`, `/v1/buildBetaDetails`, `/v1/betaAppReviewSubmissions`). But
because this publishes to strangers, do it deliberately — the UI is the safer path
for the first flip, and the public-link toggle is a one-way "we're live" moment.
