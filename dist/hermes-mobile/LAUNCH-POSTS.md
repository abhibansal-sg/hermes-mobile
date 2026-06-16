# Launch posts (drafts) — internal, NOT exported

Fill before posting:
- `REPO` = https://github.com/ab0991-oss/hermes-ios
- `TF_LINK` = external TestFlight public link (after Beta App Review clears, ~1 day)
- `@FOUNDER` = the Nous founder handle you want to tag (org account is **@NousResearch**)
- attach the recorded video

Launch is two-phase: the **repo (build-it-yourself) goes live now**; the **public
TestFlight link follows** once Apple's Beta App Review clears. Both posts lead with
"open-source today, TestFlight in review" so they work the moment the repo is up.

---

## X (aimed at Nous + the founder — keep it genuine, ask for a boost)

> I built a native iOS app for Hermes.
>
> Your agent on your phone — live streaming chat, approvals, push + Live
> Activities — talking only to your own self-hosted gateway. No third-party servers.
>
> Open-source today; a TestFlight beta for self-hosters is in review. Built it
> solo, would mean a lot to have your support 🙏
>
> @NousResearch  [REPO]
>
> [video]

Notes:
- Tag the founder (@FOUNDER) in the post or the first reply — your call which.
- If it runs long for one tweet, split: tweet 1 = the pitch + video; reply = the
  repo link + "build it yourself; TestFlight link coming when review clears."

---

## Discord (feature list — "mobile companion to Hermes desktop")

> Hey everyone — I made a native iOS app for Hermes: a **mobile companion to
> Hermes desktop** 🎉 It talks only to your own self-hosted `hermes-agent`
> gateway — no third-party servers.
>
> What it does:
> • Live multi-client streaming — desktop ↔ phone mirror the same sessions
> • Approvals & clarifications inline and from the lock screen
> • Push notifications + Live Activities / Dynamic Island
> • Home-screen widgets, file browse + attachment upload, voice dictation, Face ID lock
>
> It's **open-source (MIT)**. Setup is a self-contained gateway plugin — there's a
> guide and even a copy-paste prompt your agent can run to install it itself. You
> can **build it yourself today**; a **public TestFlight beta** is in review and the
> link will follow.
>
> Repo: [REPO]
> [attach video]
>
> It's early and I'd genuinely love feedback, testers, and help making it better 🙏

Notes:
- Honest on push: background push on the TestFlight build needs the app publisher's
  APNs key, so self-hosters get live chat / sync / in-app approvals / on-device Live
  Activity out of the box, and full background push when they build it themselves
  with their own Apple team. (Don't overclaim in the post; the README covers it.)
