# Scout report: relay_client.py + push_engine.py relay branch (ABH-208 Slice B)

Files read: plugins/hermes-mobile/relay_client.py (full, 512 lines),
plugins/hermes-mobile/push_engine.py (headers/notify/notify_live_activity
sections, ~lines 1-160 + 780-950). Grepped whole `plugins/hermes-mobile/`
tree for `HERMES_MOBILE_RELAY_URL|relay_client|relay_pairing|tunnel_status`
— zero hits outside these two files.

## Bugs

1. **relay_client.py:366-384 `_write_credentials` — credential file briefly
   world-readable, severity: HIGH.**
   The temp file is created with `tmp.write_text(...)` (default mode, subject
   to process umask — typically 644) and only `os.chmod(tmp, 0o600)` *after*
   the plaintext `agent_secret` + `pairing` capability token are already on
   disk (line 376-381). If `chmod` raises (`except OSError: pass`, line
   382-383) the file is silently left at its permissive default mode and then
   `os.replace`'d into place as the final credentials file — no further
   attempt to fix permissions. This is exactly the "creds written
   world-readable" failure mode the task called out, and it's avoidable: the
   sibling registry writer in the same plugin,
   `push_engine.py:394-402 _save_registry` → `atomic_json_write(path, ...,
   mode=0o600)`, explicitly creates the temp file at 0600 *before* writing
   bytes for this reason (see its own comment at push_engine.py:397-399).
   `relay_client.py` does not reuse that helper and reintroduces the race it
   was written to avoid.

2. **push_engine.py:826-841 `notify()` relay branch — always reports success
   regardless of delivery outcome, severity: MEDIUM-HIGH.**
   `notify()`'s docstring (line 811-824) promises "Returns the count of
   pushes accepted (HTTP 200)". In the relay branch, `send_event_background`
   is fire-and-forget by design (relay_client.py:444, "Never blocks the
   caller" — spawns a daemon thread and returns immediately). `notify()`
   still `return 1` unconditionally right after kicking off that thread
   (push_engine.py:838), before any HTTP round-trip has happened. A relay
   that's unreachable, a stale/bad token, or an auth failure inside
   `_send_sync` (relay_client.py:493-512, bare `except Exception:` swallowed
   at debug level) all produce the exact same "1 push accepted" return value
   as a real success. Any caller/gateway hook that checks `notify()`'s return
   value to decide whether to warn the user, retry, or log will never see the
   relay-mode failure — this is the "relay path that could silently drop a
   push" scenario named directly in the task brief.

3. **push_engine.py:826-829 / 935-938 relay branch — `RelayConfigurationError`
   and `NeedsAttestation` are swallowed identically to network errors,
   severity: MEDIUM.**
   Both `notify()` and `notify_live_activity()` wrap the relay call in a bare
   `except Exception: _log.debug(...); return 0/False`. This is correct for
   "never break the caller," but it means a misconfigured
   `HERMES_MOBILE_RELAY_URL` (empty/unreachable) and an enrollment that needs
   App Attest (`NeedsAttestation`, relay_client.py:92-93, 257-264) both
   degrade to an indistinguishable silent no-op — there is no separate signal
   path for "config error, please fix" vs. "transient network blip."

4. **relay_client.py:445-446 `_is_duplicate` dedupe key omits event title,
   severity: LOW.** The dedupe key is
   `f"{relay_kind}:{session_id or ''}:{(body or '')[:80]}"`. Two distinct
   events in the same 10s window that share a `session_id` (or both have
   `session_id=None`) and share the first 80 chars of body text (plausible
   for templated bodies, e.g. two different "Current phase: …" proactive
   updates with a long shared prefix) will have the second one dropped
   without any log line — combined with bug #2, `notify()` still reports
   success for the dropped call.

## Fitness (relay-mode usability)

- **Enable — PARTIAL.** Turning relay mode on is just setting
  `HERMES_MOBILE_RELAY_URL` (and optionally
  `HERMES_MOBILE_RELAY_REGISTRATION_TOKEN`) via env or the Hermes home's
  `.env` (relay_client.py:81-89, 117-123). There is no `hermes tools`
  entry, setup-wizard prompt, CLI command, or dashboard route for this in
  the plugin — the whole-directory grep found these two files as the only
  hits for the relay symbols. A user has to know the env var name exists and
  hand-edit `.env`.
- **Confirm it took effect — MISSING.** `notify()`/`notify_live_activity()`
  return values are not trustworthy signals (bug #2). `RelayClient` does
  expose `tunnel_status()` / `wait_for_tunnel_online()`
  (relay_client.py:285-321) which could answer "is this actually wired up,"
  but nothing in this plugin calls them — no CLI command, no dashboard
  route, no notify()-adjacent check. They're unreferenced outside
  `relay_client.py` itself per the directory grep, i.e. dead from the
  product's point of view in this slice.
- **Recover from a bad URL/token — MISSING.** A wrong relay URL raises
  `RelayConfigurationError`/connection errors, and a revoked/expired
  token or missing attestation raises `NeedsAttestation` — both are caught
  by the same bare `except Exception: _log.debug(...)` in push_engine.py
  (bug #3) and never surface to the user. There is no retry-with-backoff,
  no user-facing error state, and no re-enrollment prompt reachable from
  this code path.

## Verdict

Not usable end-to-end yet and not safe as written: relay mode can only be
turned on by editing `.env` by hand (no enable/confirm/recover UX exists
outside these two files), `notify()` unconditionally claims success for
relay pushes so a broken relay fails silently, and `_write_credentials`
reintroduces the exact world-readable-secret race that the plugin's own
`push_tokens.json` writer was deliberately hardened against — that's the
top fix priority (relay_client.py:366-384, mirror `atomic_json_write`'s
mode-before-write pattern).
