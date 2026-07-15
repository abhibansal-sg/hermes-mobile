# Lane F — Phase 1 Freshness Protocol issue specs

Verified against `environment-and-workflows-overview` at `73a6ee5ed7e8a4dc8ef479dd9b178bb3739f6027` on 2026-07-15. Paths and line numbers below are relative to the Hermes Mobile product repository unless stated otherwise.

## SYNC MANIFEST API CONTRACT

This section is the frozen Phase 1 interface. Every server and iOS issue below must implement or consume this contract without inventing a sibling core route, a second revision source, or a second observable publish.

### Route and ownership

`GET /api/plugins/hermes-mobile/sync/manifest`

The path is intentionally under the existing plugin mount. `plugins/hermes-mobile/dashboard/api.py:1-25` states that this router is mounted at `/api/plugins/hermes-mobile/`, while the current transcript delta is likewise plugin-owned at `api.py:1604`. No stock-core route or stock `hermes_state.py` schema change is permitted.

The route is a read-only manifest over authoritative gateway state plus a plugin-owned revision journal. The iOS client MUST collect every page for one response revision, apply the complete manifest delta in one GRDB write transaction, and then perform exactly one observable state publish covering the drawer, Inbox, active turns, transcript heads, freshness state, and widget snapshot. It MUST NOT publish page-by-page or store a cursor before the transaction commits.

### Authentication and authorization

- Send the same `X-Hermes-Session-Token: <token>` header that `RestClient.makeRequest` already adds. The bearer may be the legacy shared dashboard token or a per-device token.
- The handler MUST begin with the exact explicit gate used by `session_messages_delta` at `plugins/hermes-mobile/dashboard/api.py:1619-1622`: `_has_dashboard_api_auth(request)` or HTTP 401, followed by the relevant device scope/ownership checks. Dashboard middleware remains the outer gate; the handler check remains the belt-and-suspenders gate described at `api.py:18-25`.
- A device-token request MUST have the `chat` scope. Missing scope returns HTTP 403. Shared-token requests retain host-trusted access.
- For device-token auth, `sessions`, `pending_attention`, `active_turns`, `transcript_heads`, counts, and tombstones MUST be filtered to sessions for which `_device_owns_session(request, session_id)` is true. Missing or ambiguous ownership fails closed. A device MUST NOT learn that a foreign session exists through an upsert, aggregate, transcript head, attention item, active turn, or tombstone.
- `push_registry.device_registered` is scoped to the authenticated `request.state.device.device_id`. A shared-token request, or a legacy APNs registry row with no `device_id`, returns `false`, causing a safe re-registration. `POST /push/register` must bind new/updated APNs rows to `_request_device_id(request)` so the next manifest can return `true`; legacy rows are backfilled by re-registration, never guessed by token prefix.

### Request

Query parameters:

| Name | Required | Type | Contract |
|---|---:|---|---|
| `scope` | yes | string | Canonical cache/list universe. Exactly `all` for the aggregate profile or `profile:<percent-encoded-profile-id>` for one profile. Empty, malformed, or over 256 UTF-8 bytes is HTTP 400. The server endpoint itself supplies server identity; iOS combines the normalized scope profile with its normalized base URL to form `CacheScope(serverId, profileId)`. |
| `cursor` | no | opaque string | Omit only for a full seed/reset. A completed response's `next_cursor` is supplied unchanged on the next sync. An incomplete response's `next_cursor` is supplied unchanged for the next page. Cursors are server-issued, versioned, integrity-protected/unguessable, bound to auth visibility plus exact `scope`, and capped at 1 KiB. Clients MUST NOT parse them. |

There is deliberately no client-controlled page size. The server caps a page at 500 combined session upserts/tombstones and may choose a smaller bound to stay below its response-byte budget. This prevents a mobile caller from requesting an unbounded materialization.

Examples:

```http
GET /api/plugins/hermes-mobile/sync/manifest?scope=all
X-Hermes-Session-Token: <device-token>
```

```http
GET /api/plugins/hermes-mobile/sync/manifest?scope=profile%3Awork&cursor=<opaque>
X-Hermes-Session-Token: <device-token>
```

### Response JSON schema

All timestamps are UTC Unix epoch seconds as JSON numbers. All revisions are non-negative JSON integers. Unknown fields are additive and MUST be ignored by older clients; missing required fields fail decoding and leave the prior cursor/cache untouched.

```json
{
  "server_time": 1784101200.125,
  "revision": 1842,
  "scope": "all",
  "is_full_sync": false,
  "complete": true,
  "next_cursor": "m1.<opaque-checkpoint-or-page-token>",
  "capabilities_version": 1,
  "sessions": {
    "upserts": [
      {
        "id": "stored-session-id",
        "title": "Safe session title",
        "preview": "Safe preview",
        "started_at": 1784090000.0,
        "message_count": 12,
        "source": "cli",
        "last_active": 1784101100.0,
        "cwd": "/bounded/display/path",
        "profile": "default",
        "archived": false,
        "is_active": true,
        "revision": 1841
      }
    ],
    "tombstones": [
      {
        "session_id": "stored-session-id",
        "revision": 1842,
        "deleted_at": 1784101199.0,
        "reason": "deleted"
      }
    ]
  },
  "pending_attention": [
    {
      "id": "request-id",
      "session_id": "runtime-session-id",
      "stored_session_id": "stored-session-id",
      "kind": "approval",
      "safe_title": "Approval required",
      "detail": {
        "description": "Redacted user-visible detail",
        "choices": []
      },
      "destructive": true,
      "created_at": 1784101000.0,
      "expires_at": 1784104600.0,
      "status": "pending",
      "revision": 1840
    }
  ],
  "active_turns": [
    {
      "session_id": "runtime-session-id",
      "stored_session_id": "stored-session-id",
      "started_at": 1784100900.0,
      "state": "waiting_for_attention",
      "revision": 1840
    }
  ],
  "transcript_heads": {
    "stored-session-id": {
      "max_message_id": 9917,
      "message_count": 12,
      "last_message_at": 1784101100.0,
      "revision": 1841
    }
  },
  "widget_summary": {
    "open_session_count": 243,
    "active_turn_count": 2,
    "pending_attention_count": 1,
    "tokens_today": 18400,
    "estimated_cost_today": 0.42
  },
  "push_registry": {
    "device_registered": true
  }
}
```

Field rules:

- `revision` is the immutable target revision for every page in this logical response. It is monotonically increasing within the plugin instance and persists across restart in plugin-owned state.
- `scope` exactly echoes the normalized requested scope.
- `is_full_sync` is `true` when the request omitted a cursor or the server explicitly established a reset seed. A full sync contains every visible, non-archived session as an upsert and no tombstones. After its final page commits, iOS deletes same-scope session rows absent from the complete seed, subject only to the explicit active/pinned/live survivor rule inherited from STR-1208.
- `complete` is `false` when another page is required. Every page of a logical response has the same `revision`, `scope`, `is_full_sync`, capability version, attention/turn/widget/push snapshots, and a disjoint sessions/head slice. iOS buffers and validates pages and applies nothing until `complete == true`.
- `next_cursor` is always non-empty. When `complete == false`, it resumes the next page of the frozen revision. When `complete == true`, it is the committed checkpoint for the next delta request. It becomes durable only in the same GRDB transaction as the delta.
- `capabilities_version` versions the manifest schema/capability snapshot, beginning at `1`; a change invalidates the client's cached capability probe and triggers a nonblocking re-probe after manifest commit.
- `sessions.upserts[]` is the existing `SessionSummary`-compatible row shape required by STR-1208, plus `archived`, `is_active`, and row `revision`. Delta pages contain only rows changed after the prior completed cursor. `reason` for tombstones is exactly `deleted`, `archived`, or `filtered`. A tombstone means remove that ID from this list universe and its dependent local rows unless the STR-1208 active/pinned/live survivor rule temporarily retains it in memory; a retained survivor is not persisted back into the authoritative list mirror.
- `pending_attention` is a complete authoritative snapshot at `revision`, not an append-only delta. It replaces the scoped local pending set and uses statuses `pending`, `responding`, `resolved_elsewhere`, `expired`, or `failed_retry`. Only `pending`/`failed_retry` contribute to `pending_attention_count`. `detail` is a JSON object with redacted display-safe content; it MUST NOT include secrets or an unredacted destructive command.
- `active_turns` is a complete authoritative snapshot at `revision`. `state` is exactly `running` or `waiting_for_attention` in Phase 1.
- `transcript_heads` is keyed by stored session ID. A full sync supplies all visible heads; a delta supplies changed/upserted heads and heads for active/attention sessions. A session tombstone deletes its local head. Head mismatch schedules the existing transcript delta/backfill path; manifest application never embeds transcript bodies.
- `widget_summary.open_session_count` is the count of visible non-archived sessions in this scope, not "1 if a session is open." `active_turn_count` is the authoritative gateway count. JSON `null` is allowed only for `tokens_today` and `estimated_cost_today` when usage is unavailable; counts are always integers >= 0.
- `push_registry.device_registered` follows the authenticated device binding rule above.

The audit's §7.3 example calls one widget field `active_sessions`, while R-57 separately requires `open_session_count` and `active_turn_count`. This contract freezes the latter two precise names and does not expose the ambiguous `active_sessions` alias.

### Pagination, ordering, and atomicity

1. The server materializes one immutable, authorization-filtered logical snapshot at target `revision` and paginates that snapshot. Later mutations create a later revision and never leak into remaining pages.
2. Upserts are ordered by `(revision ASC, id ASC)` and tombstones by `(revision ASC, session_id ASC)` before deterministic slicing. Duplicate IDs within a logical response are invalid.
3. A cursor is bound to normalized scope, authorization visibility, target/base revision, and page position. Replaying a page cursor returns the same logical page and next cursor. A completed checkpoint may be retried idempotently and may return an empty delta at a newer or identical revision.
4. iOS verifies one scope/revision/capability version across pages, unions disjoint entries, and then performs one `DatabaseQueue.write` transaction that migrates/upserts/deletes scoped rows, replaces pending attention and active turns, updates transcript heads/widget data/freshness, and persists `next_cursor` plus revision. Any decode, page, validation, cancellation, expiry, or SQL failure rolls back all writes and publishes nothing.
5. After commit, iOS performs exactly one main-actor observable publish. Widget shared-store write/reload is a projection of that committed revision, never a parallel fetch or earlier publish.
6. There is no server-side guarantee that a background task will finish all pages. An interrupted client retains its last completed checkpoint and restarts the delta later; page cursors are not promoted to durable checkpoints.
7. The plugin retains cursor history for at least 30 days or 10,000 revisions per scope, whichever covers more time. Compaction below an outstanding cursor produces the reset response below; it never silently returns an incomplete delta.

### Error semantics

Errors are JSON, never HTML. They do not advance the cursor or revision on the client.

| HTTP | `code` | Meaning and client action |
|---:|---|---|
| 400 | `invalid_scope` / `invalid_cursor` | Malformed query. Keep cache/cursor; log and surface sync failure. Do not auto-wipe. |
| 401 | `unauthorized` | Exact auth gate failure (`detail: "Unauthorized"`). Stop background retries until credentials change; foreground enters re-pair flow. |
| 403 | `insufficient_scope` | Device lacks `chat`, or authorization cannot be established. Fail closed; do not fall back to a broader shared view. |
| 409 | `cursor_scope_mismatch` | Cursor belongs to another normalized scope/auth visibility. Discard only that scope's manifest cursor and request a full seed; do not wipe unrelated scopes. |
| 410 | `cursor_expired` | Journal no longer retains the base revision. Body includes `reset_required: true`; request again without `cursor` and apply a full seed atomically. |
| 429 | `rate_limited` | Honor `Retry-After`; keep current cache and freshness state. |
| 503 | `state_unavailable` | Authoritative state could not be snapshotted. Keep cached data, mark `sync_failed_cached_shown`, and retry on the next foreground/BGAppRefresh/push opportunity. |

Error body:

```json
{
  "error": {
    "code": "cursor_expired",
    "message": "Manifest cursor is no longer retained",
    "reset_required": true,
    "retry_after_seconds": null
  }
}
```

The route being absent (`404`/`405`) means the gateway predates this plugin capability. Phase 1 iOS keeps the existing foreground session/transcript fallback but cannot claim manifest freshness, atomic cross-surface revision equality, background catch-up, or authoritative tombstones on that gateway.

### Background-push invalidation contract

The plugin sends a background APNs push only after the corresponding plugin revision is durable:

```json
{
  "aps": {
    "content-available": 1
  },
  "sync": {
    "scope": "all",
    "revision": 1843,
    "reason": "attention"
  }
}
```

- `scope` uses the exact manifest scope grammar.
- `revision` is an invalidation high-water mark, not data. iOS ignores it only when the same scope's committed local revision is already >= it; otherwise it fetches the manifest using its committed cursor.
- `reason` is exactly one of `sessions`, `attention`, `active_turns`, `transcript`, `widget`, `push_registry`, or `coalesced`. It is telemetry/scheduling context only and MUST NOT select a partial apply path.
- The APNs request uses `apns-push-type: background`, `apns-priority: 5`, the app topic, and a stable per-scope collapse ID. Coalescing/missed delivery is expected; foreground sync and `BGAppRefreshTask` close the gap.
- The payload contains no session title, prompt text, counts, tokens, transcript content, or other database truth. It is not used for streaming, as a WebSocket replacement, for large downloads, or as an exact scheduler.


---

# FULL PHASE-1 ISSUE DRAFTS (recovered from lane final message)

# Lane F — Phase 1 Freshness Protocol issue specs

Verification baseline: detached HEAD `73a6ee5ed7e8a4dc8ef479dd9b178bb3739f6027`, inspected 2026-07-15.

## SYNC MANIFEST API CONTRACT

### Route and ownership

`GET /api/plugins/hermes-mobile/sync/manifest`

This path is frozen. The endpoint belongs exclusively to `plugins/hermes-mobile/`; it must not be added to the stock Hermes core, `hermes_cli/web_server.py`, or the stock `hermes_state.py` schema.

Current path selection is already represented by `APIPathStyle.plugin` and `mobileAPIPrefix` in `apps/ios/HermesMobile/Networking/Rest/RestClient.swift:27-50`. An older gateway returning `404` or `405` is a capability miss, not a reason to probe or introduce `/api/sync/manifest`.

### Authentication and authorization

The request carries the existing header:

```http
X-Hermes-Session-Token: <shared-or-device-token>
```

The plugin route must use exactly the same outer auth gate as the existing transcript-delta route:

1. Call `_has_dashboard_api_auth(request)`.
2. Return `401 {"detail":"Unauthorized","code":"unauthorized"}` if it fails.
3. For shared/dashboard-token authentication, preserve host-trusted visibility.
4. For device-token authentication, filter every session, tombstone, pending-attention item, active turn, transcript head, and derived count through `_device_owns_session(request, session_id)`.
5. Missing or ambiguous device ownership fails closed by omission. It must not leak a tombstone, title, count, transcript head, or prompt for another device.
6. An authenticated device with no owned entities receives a valid empty manifest, not `403`.

Evidence: `plugins/hermes-mobile/dashboard/api.py:104-168` defines the auth and ownership helpers; `session_messages_delta` applies `_has_dashboard_api_auth` and `_device_owns_session` at `api.py:1619-1622`.

`push_registry.device_registered` is scoped to `_request_device_id(request)`. To make it truthful, `POST /push/register` must bind the APNs registration to the authenticated device ID. Current `PushRegisterBody` and `push_engine.register_token` do not store that association (`api.py:1037-1043`, `api.py:1311-1322`, `push_engine.py:455-500`).

### Request parameters

| Parameter | Required | Contract |
|---|---:|---|
| `scope` | yes | `all` or `profile:<percent-encoded-profile-id>` |
| `cursor` | no | Opaque manifest cursor returned by the preceding successful manifest response |

Scope rules:

- `all` is the cross-profile aggregate.
- `profile:default` identifies the default profile.
- Named profile IDs are case-sensitive, decoded exactly once as UTF-8, and limited to 1–128 bytes after decoding.
- Empty profile IDs, control characters, malformed percent escapes, and the reserved literal `profile:all` are invalid.
- `scope` is a synchronization universe, not a cache row identity. Under `scope=all`, each session still carries its actual `profile`; `(server_id, actual_profile_id, session_id)` remains the database identity.
- The client’s `server_id` comes from the existing trimmed `ConnectionStore.serverURLString`; the server identity is not accepted from an untrusted query parameter.

Cursor rules:

- Omitted cursor requests an authoritative full seed.
- A cursor is opaque, bound to the authenticated visibility identity and exact scope, and limited to 1 KiB.
- Clients must never parse or construct cursors.
- There is no client-controlled page-size parameter. Version 1 caps each response at 500 changed entity records.
- The final page’s `next_cursor` is the durable checkpoint for the next delta.
- A non-final page’s `next_cursor` is only a continuation token and must not be persisted as the completed checkpoint.

### Response JSON Schema

The following Draft 2020-12 schema is normative:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://hermes.local/schemas/mobile-sync-manifest-v1.json",
  "title": "Hermes Mobile Sync Manifest v1",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "server_time",
    "revision",
    "scope",
    "is_full_sync",
    "complete",
    "next_cursor",
    "capabilities_version",
    "sessions",
    "pending_attention",
    "active_turns",
    "transcript_heads",
    "widget_summary",
    "push_registry"
  ],
  "properties": {
    "server_time": {
      "type": "number",
      "minimum": 0,
      "description": "Unix epoch seconds captured for the immutable manifest snapshot."
    },
    "revision": {
      "$ref": "#/$defs/revision"
    },
    "scope": {
      "type": "string",
      "minLength": 1,
      "maxLength": 256,
      "pattern": "^(all|profile:.+)$"
    },
    "is_full_sync": {
      "type": "boolean"
    },
    "complete": {
      "type": "boolean"
    },
    "next_cursor": {
      "type": "string",
      "minLength": 1,
      "maxLength": 1024
    },
    "capabilities_version": {
      "type": "integer",
      "minimum": 1
    },
    "sessions": {
      "type": "object",
      "additionalProperties": false,
      "required": ["upserts", "tombstones"],
      "properties": {
        "upserts": {
          "type": "array",
          "items": {"$ref": "#/$defs/sessionUpsert"}
        },
        "tombstones": {
          "type": "array",
          "items": {"$ref": "#/$defs/sessionTombstone"}
        }
      }
    },
    "pending_attention": {
      "type": "array",
      "items": {"$ref": "#/$defs/pendingAttention"}
    },
    "active_turns": {
      "type": "array",
      "items": {"$ref": "#/$defs/activeTurn"}
    },
    "transcript_heads": {
      "type": "array",
      "items": {"$ref": "#/$defs/transcriptHead"}
    },
    "widget_summary": {
      "$ref": "#/$defs/widgetSummary"
    },
    "push_registry": {
      "type": "object",
      "additionalProperties": false,
      "required": ["device_registered"],
      "properties": {
        "device_registered": {
          "type": "boolean"
        }
      }
    }
  },
  "$defs": {
    "revision": {
      "type": "integer",
      "minimum": 0
    },
    "unixTime": {
      "type": "number",
      "minimum": 0
    },
    "nullableUnixTime": {
      "type": ["number", "null"],
      "minimum": 0
    },
    "nullableString": {
      "type": ["string", "null"]
    },
    "profileId": {
      "type": "string",
      "minLength": 1,
      "maxLength": 128,
      "description": "Actual row profile; never the aggregate sentinel 'all'."
    },
    "sessionUpsert": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "id",
        "profile",
        "title",
        "preview",
        "started_at",
        "message_count",
        "source",
        "last_active",
        "cwd",
        "archived",
        "is_active",
        "revision"
      ],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "profile": {"$ref": "#/$defs/profileId"},
        "title": {"type": "string"},
        "preview": {"$ref": "#/$defs/nullableString"},
        "started_at": {"$ref": "#/$defs/nullableUnixTime"},
        "message_count": {"type": "integer", "minimum": 0},
        "source": {"$ref": "#/$defs/nullableString"},
        "last_active": {"$ref": "#/$defs/nullableUnixTime"},
        "cwd": {"$ref": "#/$defs/nullableString"},
        "archived": {"type": "boolean"},
        "is_active": {"type": "boolean"},
        "revision": {"$ref": "#/$defs/revision"}
      }
    },
    "sessionTombstone": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "session_id",
        "profile",
        "revision",
        "deleted_at",
        "reason"
      ],
      "properties": {
        "session_id": {"type": "string", "minLength": 1},
        "profile": {"$ref": "#/$defs/profileId"},
        "revision": {"$ref": "#/$defs/revision"},
        "deleted_at": {"$ref": "#/$defs/unixTime"},
        "reason": {
          "type": "string",
          "enum": ["deleted", "archived", "filtered"]
        }
      }
    },
    "attentionDetail": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "prompt",
        "description",
        "target",
        "choices",
        "request_id"
      ],
      "properties": {
        "prompt": {"$ref": "#/$defs/nullableString"},
        "description": {"$ref": "#/$defs/nullableString"},
        "target": {"$ref": "#/$defs/nullableString"},
        "choices": {
          "type": "array",
          "items": {"type": "string"}
        },
        "request_id": {"$ref": "#/$defs/nullableString"}
      }
    },
    "pendingAttention": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "id",
        "session_id",
        "stored_session_id",
        "profile",
        "kind",
        "safe_title",
        "detail",
        "destructive",
        "created_at",
        "expires_at",
        "status",
        "revision"
      ],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "session_id": {"type": "string", "minLength": 1},
        "stored_session_id": {"$ref": "#/$defs/nullableString"},
        "profile": {"$ref": "#/$defs/profileId"},
        "kind": {
          "type": "string",
          "enum": ["approval", "clarify"]
        },
        "safe_title": {"type": "string"},
        "detail": {"$ref": "#/$defs/attentionDetail"},
        "destructive": {"type": "boolean"},
        "created_at": {"$ref": "#/$defs/unixTime"},
        "expires_at": {"$ref": "#/$defs/nullableUnixTime"},
        "status": {
          "type": "string",
          "const": "pending"
        },
        "revision": {"$ref": "#/$defs/revision"}
      }
    },
    "activeTurn": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "session_id",
        "stored_session_id",
        "profile",
        "started_at",
        "state",
        "revision"
      ],
      "properties": {
        "session_id": {"type": "string", "minLength": 1},
        "stored_session_id": {"$ref": "#/$defs/nullableString"},
        "profile": {"$ref": "#/$defs/profileId"},
        "started_at": {"$ref": "#/$defs/nullableUnixTime"},
        "state": {
          "type": "string",
          "enum": ["starting", "running", "waiting_for_attention"]
        },
        "revision": {"$ref": "#/$defs/revision"}
      }
    },
    "transcriptHead": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "session_id",
        "profile",
        "max_message_id",
        "message_count",
        "last_message_at",
        "revision"
      ],
      "properties": {
        "session_id": {"type": "string", "minLength": 1},
        "profile": {"$ref": "#/$defs/profileId"},
        "max_message_id": {
          "type": ["integer", "null"],
          "minimum": 0
        },
        "message_count": {"type": "integer", "minimum": 0},
        "last_message_at": {"$ref": "#/$defs/nullableUnixTime"},
        "revision": {"$ref": "#/$defs/revision"}
      }
    },
    "widgetSummary": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "open_session_count",
        "active_turn_count",
        "pending_attention_count",
        "tokens_today",
        "estimated_cost_today"
      ],
      "properties": {
        "open_session_count": {"type": "integer", "minimum": 0},
        "active_turn_count": {"type": "integer", "minimum": 0},
        "pending_attention_count": {"type": "integer", "minimum": 0},
        "tokens_today": {
          "type": ["integer", "null"],
          "minimum": 0
        },
        "estimated_cost_today": {
          "type": ["number", "null"],
          "minimum": 0
        }
      }
    }
  }
}
```

`transcript_heads` is deliberately an array rather than an object keyed only by session ID. An object cannot represent two rows with the same session ID in different profiles without inventing an encoded composite key, conflicting with R-46.

### Entity semantics

- `revision` is a durable, plugin-owned, monotonically increasing 64-bit integer.
- `revision` covers all fields in the immutable response snapshot, including capabilities, attention, active turns, transcript heads, widget summary, and push-registration state.
- Session upserts use stored/persistent session IDs.
- Every session-derived entity carries its actual profile.
- A delta tombstone means the authoritative cached row must be removed even if it is temporarily retained as an in-memory active/pinned/live working-set survivor.
- A working-set survivor is a UI overlay only. It must not be written back as authoritative cache state after a tombstone.
- `pending_attention` and `active_turns` are authoritative complete snapshots across the union of all returned pages.
- `pending_attention` contains only actionable `approval.request` and `clarify.request` prompts. Sudo, secret, and generic input prompts are excluded.
- `transcript_heads` is complete during a full sync. During a delta it includes changed/upserted/active/attention-bearing sessions. A tombstone removes the corresponding head.
- A head mismatch schedules the existing transcript-delta fetch; the manifest does not carry transcript bodies.
- `widget_summary.open_session_count` means visible, non-archived sessions in the requested scope.
- `active_turn_count` means current running or waiting turns. It is not the currently opened iOS chat.
- Usage values may be `null` only when the gateway cannot calculate them. Zero is a real value and must not be substituted for unavailable data.
- `device_registered` is true only when an APNs token registry entry is bound to the authenticated `_request_device_id`.

### Pagination, consistency, and atomicity

1. The server captures one immutable, authorization-filtered target snapshot and target revision before returning page one.
2. All pages for a cursor chain return identical `server_time`, `revision`, `scope`, `is_full_sync`, `capabilities_version`, `widget_summary`, and `push_registry`.
3. Entity slices are deterministic and disjoint, ordered by entity type, entity revision, actual profile, and entity ID.
4. `complete=false` means another continuation request is required.
5. `complete=true` means the union of all pages is authoritative.
6. Replaying a page or final checkpoint is idempotent.
7. No-cursor full sync returns every visible session and complete attention/turn/head snapshots. At final apply, rows absent from the full union are deleted for that manifest scope.
8. Delta sync returns changes after the checkpoint, including tombstones.
9. The plugin retains cursor history for at least 30 days or 10,000 revisions, whichever retains more history.
10. The iOS client validates every page before mutation, buffers the complete chain, and applies it through one `DatabaseQueue.write` transaction.
11. That transaction updates sessions, tombstones, attention, turns, transcript heads, manifest revision/cursor, capability version, last-sync time, widget source data, and push-registration state together.
12. Any decode, scope, revision, page-order, or database failure rolls back the entire apply and retains the last completed cursor.
13. After commit, iOS publishes one immutable observable manifest projection on `MainActor`.
14. Widget projection occurs only after the database commit. A failed transaction cannot advance the widget revision.
15. Background expiration or cancellation before the final page performs no partial apply.

Server-side “atomic” means a plugin synchronization lock, a read transaction over `state.db`, and snapshots of `_sessions` and `_pending` under their existing locks. Events after the captured cutoff receive a later revision.

### Error semantics

All application errors use:

```json
{
  "detail": "Human-readable explanation",
  "code": "stable_machine_code",
  "reset_required": false
}
```

`reset_required` is omitted unless relevant.

| Status | Code | Client behavior |
|---:|---|---|
| 400 | `invalid_scope` | Keep cache; surface diagnostics; do not retry unchanged request |
| 400 | `invalid_cursor` | Keep cache; retry once without cursor |
| 401 | `unauthorized` | Enter re-pair flow; do not erase cache |
| 409 | `cursor_scope_mismatch` | Reset only the requested manifest scope and retry full |
| 410 | `cursor_expired` | `reset_required=true`; retry full for that scope |
| 429 | `rate_limited` | Honor `Retry-After`; continue showing cache |
| 500 | `manifest_internal_error` | Keep cache and cursor; exponential retry |
| 503 | `manifest_state_unavailable` | Keep cache and cursor; report cached/offline state |

A `404` or `405` means the plugin manifest capability is absent. iOS falls back to PR #147’s scoped session delta or the current full-list path, retains live-event Inbox behavior, and labels the resulting state `partial`; it must not claim full freshness.

### Background-push invalidation contract

Normative APNs body:

```json
{
  "aps": {
    "content-available": 1
  },
  "sync": {
    "scope": "all",
    "revision": 1843,
    "reason": "attention"
  }
}
```

Rules:

- `aps.content-available` is numeric `1`.
- There is no alert, badge, sound, session title, prompt text, transcript body, or other user data.
- `sync.scope` uses the manifest scope grammar.
- `scope=all` is a gateway-wide invalidation. A client fetches its currently selected manifest scope and records other known scopes dirty.
- A `profile:<id>` invalidation is fetched immediately only when that scope is active; otherwise it is recorded dirty.
- `sync.revision` is the durable manifest high-water revision that caused the invalidation.
- `reason` is one of `sessions`, `attention`, `active_turns`, `transcript`, `widget`, `push_registry`, or `coalesced`.
- APNs headers are `apns-push-type: background`, `apns-priority: 5`, the app topic, and a per-scope collapse identifier no longer than 64 bytes.
- The payload is only an invalidation hint. iOS always fetches the manifest and never applies payload values as data.
- Silent pushes are discretionary, coalesced, and unavailable after force quit until the next manual launch. Foreground and `BGAppRefreshTask` sync remain mandatory recovery paths.
- They are not used for streaming tokens, WebSocket replacement, attachments, or exact scheduling.

## VERIFIED CURRENT-CODE FINDINGS

- `CacheSchema.swift:47-79` creates `session_cache` with primary key `id`, `message_row_cache` with `(sessionId, ordinal)`, and global `sync_meta.key`.
- The v2 migration at `CacheSchema.swift:117-149` only adds `serverId` and `profileId` columns plus an index. Neither column joins a primary key.
- `SessionCacheRecord.swift:58-70` claims server/profile are “ALWAYS part of the key,” contradicting the SQL schema.
- `CacheStore.saveSessionList` fetches existing rows by `summary.id` at `CacheStore.swift:98-110`; transcript APIs similarly fetch/filter by session ID alone at `CacheStore.swift:142-189`.
- `CacheStore.init` invokes `nukeIfSchemaMismatch` before running migrations (`CacheStore.swift:29-42`). Advancing the fingerprint from v2 would therefore erase the cache unless this flow changes.
- `AttachmentBlobCache.Key` already uses `(serverId, profileId, sessionId, path, size)` at `AttachmentBlobCache.swift:22-74`.
- No GRDB pending-attention, active-turn, outbox, last-opened, or panel-snapshot tables exist.
- `WidgetSnapshotWriter.lastWritten` is process-local (`WidgetSnapshotWriter.swift:30`), and omitted usage is preserved only from that static value (`:51-54`).
- `AppEnvironment` writes a pre-bootstrap widget snapshot at `AppEnvironment.swift:197-215`, confirming the cold-process overwrite risk.
- The current widget “active sessions” value is `1` when one iOS session is open and `0` otherwise (`AppEnvironment.swift:219-225`).
- `StatusWidget` can indefinitely render a green “Connected” dot from a persisted Boolean (`StatusWidget.swift:91-94`, `:153-164`).
- `.hydrating` directly returns `HydrationLoadingView` in `RootView.swift:129-143`; that view is a full-screen branded loader (`HydrationLoadingView.swift:16-35`).
- Cache-first disk painting already precedes network setup at `ConnectionStore.swift:774-844`. The fix must preserve that flow and change presentation/orchestration, not rebuild bootstrap.
- `SessionStore.refresh` still performs full list fetches in this checkout (`SessionStore.swift:1771-1929`), while the 30-second heartbeat calls `refresh()` at `:2372-2385`.
- Cache list persistence is upsert-only and deliberately never deletes absent rows (`SessionStore.swift:2102-2112`).
- Inbox state is process-memory live-event accumulation (`InboxStore.swift:6-30`, `:91-105`, `:143-215`).
- Server-side FTS already exists in the plugin at `dashboard/api.py:1412-1505`; iOS search is remote-only and clears/fails without a REST client at `SessionStore.swift:3152-3235`.
- There is no `BGTaskScheduler`, remote-notification fetch callback, or manifest client in `apps/ios`.
- `Info.plist` has neither `UIBackgroundModes` nor `BGTaskSchedulerPermittedIdentifiers`.
- `Entitlements/HermesMobile.entitlements:5-10` already contains the app group and `aps-environment`.
- `AppDelegate` currently forwards only APNs registration success/failure (`HermesMobileApp.swift:365-386`).
- The plugin push registry has no authenticated device-ID binding (`api.py:1037-1043`, `push_engine.py:455-500`).

## SPEC-VS-CODE DISCREPANCIES

1. **PR #147 could not be inspected.** `gh pr diff 147 --repo abhibansal-sg/hermes-mobile` could not reach GitHub, and no local PR ref/object is present. The checked-out code still lacks `updated_since`, session tombstones, and the PR’s iOS cursor consumer. The drafts therefore build on STR-1208’s frozen contract and require a post-merge overlap audit.
2. **Scope columns are not identity.** The comments say they are; the actual SQL primary keys say otherwise.
3. **Fingerprint migration contradicts long-dormancy preservation.** A routine v3 fingerprint bump would delete the cache before GRDB can migrate it.
4. **R-46 overstates attachment work.** The filesystem attachment cache is already scope-qualified. There is no GRDB attachment table to migrate.
5. **R-46 names future tables that do not exist.** Creating unused Phase-2 outbox or Phase-3 panel tables now would be speculative infrastructure. The Phase-1 migration establishes the identity invariant and applies it only to concrete Phase-1 consumers.
6. **The §7.3 example’s `transcript_heads: {}` is under-specified.** A session-ID-keyed object cannot satisfy composite profile identity. The frozen contract uses an array.
7. **The §7.3 `active_sessions` widget name conflicts with R-57.** The contract freezes the truthful split `open_session_count` and `active_turn_count`.
8. **The cache-first launch path partially exists.** R-40’s remaining defect is specifically the post-connect `.hydrating` presentation and missing freshness state.
9. **Remote search exists; offline search does not.** R-52 is an iOS GRDB/merge task, not a new server-search endpoint.
10. **Disconnect is not Forget Gateway.** `ConnectionStore.disconnect()` intentionally retains credentials/cache semantics (`ConnectionStore.swift:1110-1160`). R-52 must expose a purge primitive for the future Forget transaction without silently changing Disconnect.
11. **R-43 crosses into Phase 2.** Durable sending without a runtime requires the SQLite outbox and idempotency work explicitly assigned to Phase 2. Phase 1 can keep reading/search/composition available and must not claim a volatile queue is durable.
12. **R-70 crosses into Phase 3.** Phase 1 can cover Sessions, Inbox, shell, and Widgets from the manifest. Devices, Cron, Usage, Skills, Providers, and Artifacts need later resource-specific revisions.
13. **STR-332 and STR-9 remain adjacent work.** PR #24’s `shape=skeleton` and around-route paging should land independently. They are not prerequisites for the manifest’s cache/revision semantics.

## PHASE 1 ISSUE DRAFTS

### ISSUE: Migrate the cache to scope-qualified identities

Phase: 1 | Spec: R-46 | Priority: high | Labels: type:fix, area:ios  
Depends-on: PR #147 landed and re-audited | Inherited-context: STR-969, STR-1208 | Estimate: L

The v2 schema only indexes scope; it does not include scope in identity. `CacheSchema.swift:47-79` uses `id` and `(sessionId, ordinal)` as primary keys, while `CacheStore.swift:98-110` and `:142-189` fetch by unscoped session ID. This allows a same-ID write from another profile to overwrite the prior row.

Implement a non-destructive v3 shadow-table migration:

- `session_cache`: primary key `(serverId, profileId, id)`, where `profileId` is the row’s actual profile, not the aggregate request scope.
- `message_row_cache`: add `serverId` and `profileId`; primary key `(serverId, profileId, sessionId, ordinal)`; composite foreign key to `session_cache` with cascade.
- `manifest_scope_state`: primary key `(serverId, manifestScope)` with revision, final cursor, capabilities version, server time, local fetched time, widget JSON, and device-registration state.
- `pending_attention_cache`: primary key `(serverId, profileId, id)`.
- `active_turn_cache`: primary key `(serverId, profileId, sessionId)`.
- `transcript_head_cache`: primary key `(serverId, profileId, sessionId)`.
- `last_opened_session`: one scoped record per `(serverId, manifestScope)`, carrying actual profile and session ID.
- Keep genuinely global cache metadata separate from scoped synchronization metadata.

Replace ID-only cache APIs with explicit composite identity/scope parameters. An aggregate list query reads all actual profiles belonging to its manifest scope. Named-profile queries filter the actual profile.

Do not call `nukeIfSchemaMismatch` for a recognized v2 database. Migrate v2 rows in place through shadow tables, verify counts and foreign keys, then atomically rename. Legacy unattributed rows remain under the existing legacy sentinel and cannot appear in a live scope.

`AttachmentBlobCache` already has the required composite identity; test it but do not introduce a duplicate GRDB attachment table. Do not pre-create Phase-2 outbox or Phase-3 panel tables.

Acceptance criteria:

- [ ] Two sessions with the same ID on two profiles coexist and load independently.
- [ ] Messages, attention, turns, heads, and last-opened state cannot cross server/profile identity.
- [ ] Deleting one scoped session cascades only its own transcript rows.
- [ ] A v2 database migrates to v3 without deleting cached sessions or transcripts.
- [ ] Opening after a week can still paint the migrated cache before any network request.
- [ ] Aggregate manifest scope remains distinct from each row’s actual profile identity.
- [ ] All `CacheStore` transcript/session/meta APIs require explicit scope or composite identity.
- [ ] Recognized schema upgrades no longer invoke the destructive fingerprint escape hatch.
- [ ] The design documents the same composite-key requirement for future outbox/panel tables without creating unused schema.

Tests required: Extend `apps/ios/HermesMobileTests/CacheLayerTests.swift` with v2 fixture migration, duplicate-ID cross-profile, composite cascade, aggregate-scope, and rollback tests. Inspect `PRAGMA table_info`, `foreign_key_list`, and indexes. Run through `scripts/ios-build.sh test`, never raw `xcodebuild`.

### ISSUE: Add the plugin sync-manifest endpoint and revision journal

Phase: 1 | Spec: R-05/R-09/R-44/R-45/R-54 | Priority: high | Labels: type:feature, area:server  
Depends-on: PR #147/STR-1208 merged; scoped identity issue may proceed in parallel | Inherited-context: STR-969, STR-1208 | Estimate: L

Add `GET /sync/manifest` to the existing router in `plugins/hermes-mobile/dashboard/api.py`, producing the frozen contract above. Put revision, cursor, snapshot, and diff logic in a focused plugin module such as `plugins/hermes-mobile/sync_manifest.py`.

Build on PR #147’s session cursor/tombstone implementation. Do not create a second incompatible tombstone feed or discard its filters. If PR #147’s revision state is process-memory-only, extend it into the manifest’s plugin-owned durable journal.

The journal must live under profile-aware `HERMES_HOME`, use SQLite/WAL and restrictive file permissions, and contain:

- A durable global revision allocator.
- Per-scope and per-visibility entity snapshots.
- Change/tombstone history.
- Opaque cursor records bound to scope and shared/device visibility.
- Cursor expiration metadata.
- Dirty/invalidation reasons.

Capture session state from read-only `SessionDB`, pending attention from `_pending` and `_pending_prompt_payloads` under `_prompt_lock`, and active turns from `_sessions` under `_sessions_lock`. The existing approval REST path demonstrates these runtime seams at `dashboard/api.py:419-458`; gateway dictionaries/locks are declared at `tui_gateway/server.py:128-138`.

Full-sync deletion detection compares the new authorized universe to the stored authorized snapshot. Device-token snapshots must never store or return unauthorized entity payloads. Foreground reads must detect state changes even when an event hook was missed.

Bind push registrations to `_request_device_id` in `api.py:1311-1322` and `push_engine.register_token`. `device_registered` is computed from that binding, not from “any APNs token exists.”

Do not modify stock-core routes or stock database schema. Usage failures produce nullable manifest metrics rather than failing the whole manifest.

Acceptance criteria:

- [ ] The exact frozen request, response, auth, error, pagination, and cursor contract is implemented under the plugin mount.
- [ ] A cold request produces an authoritative full seed and durable checkpoint cursor.
- [ ] A no-change cursor request is a small, idempotent delta.
- [ ] Deleted, archived, and newly filtered sessions produce monotonic tombstones.
- [ ] Device authentication filters rows, tombstones, prompts, heads, turns, and all derived counts.
- [ ] Cursor replay, scope mismatch, ownership mismatch, and expiration follow the frozen errors.
- [ ] Pending attention and active turns are captured under their existing locks.
- [ ] All pages remain at one immutable revision while concurrent changes move to a later revision.
- [ ] The endpoint survives plugin/gateway restart without resetting revision or resurrecting deleted sessions.
- [ ] A week-old cursor within retention reconciles without a mandatory full download.
- [ ] The implementation contains no stock-core route or `hermes_state.py` schema modification.

Tests required: Add focused plugin tests for schema validation, shared/device auth, no-leak counts, tombstones, full absence reconciliation, pagination replay, cursor retention/expiry, concurrent mutation, restart persistence, pending prompt capture, active turns, usage-null fallback, and device-bound push status. Add an E2E test with a temporary `HERMES_HOME`, real plugin import/router, real SQLite files, and the existing session DB path.

### ISSUE: Apply manifest deltas atomically on iOS

Phase: 1 | Spec: R-05/R-09/R-42/R-44/R-45/R-54 | Priority: high | Labels: type:feature, area:ios  
Depends-on: scoped cache migration; plugin sync-manifest endpoint; PR #147 | Inherited-context: STR-969, STR-1208 | Estimate: L

Add manifest wire models and a plugin-only `RestClient.syncManifest(scope:cursor:)`. Current request plumbing already carries `X-Hermes-Session-Token` (`RestClient.swift:53-85`), and `messagesDelta` demonstrates plugin-only capability fallback (`RestClient.swift:238-281`).

Introduce an app-owned `SyncCoordinator` and a single immutable `ManifestProjection` observable state hub. It must:

1. Paint cached manifest projection and last-opened transcript before networking.
2. Resolve the saved Keychain credential.
3. Begin manifest recovery immediately; it must not wait for WebSocket hydration.
4. Open/recover the WebSocket without allowing event order to overwrite a newer manifest revision.
5. Fetch and validate every manifest page.
6. Apply the complete chain through one `CacheStore` transaction.
7. Publish one `ManifestProjection` assignment on `MainActor`.
8. Re-register APNs when the authenticated device reports unregistered.
9. Reconcile capabilities.
10. Compare the visible transcript with `transcript_heads` and use the existing transcript-delta route when necessary.
11. Start recent-transcript prefetch only after the shell is interactive.

Sessions, Inbox, active turns, freshness, and widget source data must derive from the same projection revision. Replace `InboxStore`’s purely live-event authority (`InboxStore.swift:91-215`) with manifest-backed pending items plus a transient response overlay. WebSocket events may optimistically add/change state only at a provisional revision and must converge on the next manifest.

Tombstones always remove GRDB rows. PR #147’s active/pinned/live survivor behavior remains an in-memory working-set overlay and cannot repersist deleted cache state.

On `404/405`, retain PR #147’s cursor session delta/full-list fallback and existing live Inbox, but publish freshness as `partial`. Once manifest capability is detected, stop independent session-list writers from racing the manifest transaction.

Foreground activation, reconnect, explicit pull-to-refresh, background push, and `BGAppRefreshTask` all call the same coordinator. Concurrent triggers coalesce to one in-flight fetch; a higher invalidation revision schedules one follow-up.

Acceptance criteria:

- [ ] All pages validate before any cache mutation.
- [ ] Sessions, tombstones, attention, turns, heads, widget source, cursor, and revision commit in one GRDB transaction.
- [ ] A failed page/decode/write leaves the old revision, cursor, drawer, Inbox, and widget intact.
- [ ] One successful commit causes one observable manifest publish.
- [ ] Deleted sessions do not reappear offline after successful reconciliation.
- [ ] Inbox, drawer, and widget source data expose the same server revision.
- [ ] Empty deltas do not rebuild the loaded drawer or reset PR #147 pagination state.
- [ ] Active/pinned/live survivors remain visible only as temporary overlays after a tombstone.
- [ ] A transcript-head mismatch schedules a delta fetch without blocking cached reading.
- [ ] Old gateways remain usable and are labeled partial rather than fresh.
- [ ] Foreground sync recovers a missed push.
- [ ] Opening after a week paints the cached projection before the manifest request completes.

Tests required: Add `SyncManifestClientTests.swift`, `SyncCoordinatorTests.swift`, and atomic-apply tests around `CacheStore`. Cover multi-page validation, rollback, duplicate replay, cursor reset, old-gateway fallback, same-ID cross-profile data, tombstone survivor overlays, WebSocket/manifest race ordering, coalesced triggers, attention reconciliation, one-publish counting, and app relaunch from a week-old fixture.

### ISSUE: Show cached content and honest freshness during sync

Phase: 1 | Spec: R-13/R-40/R-41/R-43/R-69/R-70 | Priority: high | Labels: type:fix, area:ios  
Depends-on: atomic iOS manifest apply | Inherited-context: STR-969, STR-332 | Estimate: M

`RootView.swift:129-143` currently replaces the shell with `HydrationLoadingView` whenever the verified connection enters `.hydrating`, even though `ConnectionStore.bootstrap()` has already painted disk cache at `ConnectionStore.swift:774-844`.

Render `mainUI` during `.hydrating` whenever the active scope has any cached manifest/session/last-opened state. Reserve `HydrationLoadingView` for a true empty-cache first launch.

Add a reusable freshness presentation backed by the persisted manifest state:

- `Connecting`
- `Syncing`
- `Fresh`
- `Offline · Last synced …`
- `Sync failed · Cached data shown`
- `Partial result`

Restore the cached last-opened session and transcript when available. Keep drawer reading, transcript reading, offline FTS search, and composition enabled. Disable or clearly gate destructive remote actions—including delete/archive and approval/clarification responses—until a fresh, connected authority is established.

Do not describe an in-memory send queue as durable. If no runtime is available, composition remains available but the UI must not promise that Send was durably queued; that guarantee belongs to the Phase-2 SQLite outbox/idempotency work.

Phase 1 applies common freshness language to the shell, Sessions, Inbox, and Widgets. Resource-specific revision support for Devices, Cron, Usage, Skills, Providers, and Artifacts remains Phase 3.

Acceptance criteria:

- [ ] A returning user with cached content never sees the full-screen hydration loader.
- [ ] A true first launch or empty active scope still receives the branded loader.
- [ ] Opening after a week immediately shows cached drawer and last-opened transcript.
- [ ] Last-sync time survives process death and uses the committed manifest timestamp.
- [ ] Offline, syncing, failed-cached, partial, and fresh states have distinct text and accessibility labels.
- [ ] Reading, search, and composition remain available while synchronization runs.
- [ ] Destructive actions are disabled with an explanation until freshness is established.
- [ ] The UI never labels volatile no-runtime sending as durable.
- [ ] iPhone compact and iPad split layouts use the same freshness source and do not regress selection.
- [ ] The existing 8-second hydration recovery behavior remains non-stranding without controlling shell visibility.

Tests required: Extend `ConnectionPhaseTests.swift` and `CacheFirstLaunchTests.swift`; add RootView/UI tests for cache-present versus empty-cache hydration, week-old timestamps, stale/error/partial labels, destructive-action gates, VoiceOver text, iPhone/iPad layouts, and no loader flash after cached paint. Land PR #24 separately and verify its skeleton hydration still works under the cached shell.

### ISSUE: Emit background manifest invalidation pushes

Phase: 1 | Spec: R-06(part)/R-33 | Priority: high | Labels: type:feature, area:server  
Depends-on: plugin sync-manifest endpoint | Inherited-context: STR-969 | Estimate: M

Add a plugin-owned invalidation publisher that durably advances the manifest revision and sends the frozen silent APNs payload. Reuse `build_push_headers` in `push_engine.py:196-221`, but add a dedicated background-send path using `push_type="background"` and priority `5`. Do not route the payload through `build_alert_payload`.

Hook invalidation into plugin-visible session changes, archive/delete operations, prompt add/remove, active-turn changes, transcript-head changes, widget summary changes, and push registration changes. Foreground manifest snapshot diff remains the safety net when a hook is missed.

All registered devices receive sync invalidations independently of visible-alert event preferences. Alert preferences in `PUSH_EVENT_KINDS` (`push_engine.py:411-420`) continue to control alert pushes only.

Direct APNs and relay delivery must preserve the same silent payload and headers. Coalesce by scope and emit the highest revision. Push failures never block the state mutation or manifest revision.

Out of scope: durable server `push_outbox`/APNs diagnostics from R-28/R-78, streaming tokens, attachment downloads, and delivery guarantees.

Acceptance criteria:

- [ ] The payload and APNs headers match the frozen contract byte-for-byte.
- [ ] No title, body, badge, sound, session content, or prompt content is included.
- [ ] Each invalidation revision already exists durably before push enqueue/send.
- [ ] Repeated same-scope events coalesce to the highest revision.
- [ ] Session deletion/archive, pending attention, active turns, transcript heads, widgets, and push registration each invalidate the correct scope.
- [ ] Device visibility is not leaked through payload shape or reason.
- [ ] Direct and relay transports preserve background semantics.
- [ ] Alert-notification preferences remain unchanged.
- [ ] APNs/relay failure does not fail the user’s original operation.

Tests required: Add pure payload/header tests, per-scope collapse tests, event-to-reason mapping, coalescing/high-water tests, no-data-leak tests, direct/relay parity, token pruning behavior, and restart persistence of the invalidated revision.

### ISSUE: Handle silent sync pushes on iOS

Phase: 1 | Spec: R-06(part)/R-33 | Priority: high | Labels: type:feature, area:ios  
Depends-on: atomic iOS manifest apply; background invalidation server issue | Inherited-context: STR-969 | Estimate: M

Extend `AppDelegate` in `HermesMobileApp.swift:365-386` with:

```swift
application(
  _:didReceiveRemoteNotification:fetchCompletionHandler:
)
```

Validate only the frozen `sync` envelope. Forward it to a process-safe bridge attached to `SyncCoordinator`; cold-launch delivery must queue until the coordinator is ready.

The handler must never trust the payload as data. It coalesces stale/duplicate revisions, fetches the active manifest scope, applies through the common atomic coordinator, refreshes the widget after commit, and invokes the UIKit completion exactly once with `.newData`, `.noData`, or `.failed`.

Update the canonical `apps/ios/project.yml`, regenerate `HermesMobile.xcodeproj`, and update `HermesMobile/Info.plist` to include `UIBackgroundModes` with `remote-notification`. Preserve `Entitlements/HermesMobile.entitlements` and its existing `aps-environment`; no new entitlement dictionary key is required. Ensure the target’s Background Modes/Remote notifications capability remains represented in the generated project/signing configuration.

The handler must observe cancellation/background time constraints and perform no partial apply.

Acceptance criteria:

- [ ] A valid higher-revision silent push triggers the common manifest fetch/apply path.
- [ ] A duplicate or older revision returns `.noData` without unnecessary database publication.
- [ ] Malformed/non-sync notifications are ignored safely.
- [ ] Completion is called exactly once on success, no-change, cancellation, and failure.
- [ ] Cold-launch delivery waits for coordinator attachment without losing the invalidation.
- [ ] Widget projection advances only after the same manifest transaction commits.
- [ ] `UIBackgroundModes` contains `remote-notification` in source and generated project output.
- [ ] The existing APNs entitlement and registration callbacks remain intact.
- [ ] Foreground/app-refresh recovery remains correct when iOS coalesces or omits pushes.
- [ ] Tests and UI copy do not claim force-quit delivery is available.

Tests required: Unit-test payload decoding, revision coalescing, cold-launch bridge, exactly-once completion, cancellation, malformed envelopes, and widget ordering. Add plist/project-generation assertions and an integration test with a stub URL protocol and temporary GRDB database.

### ISSUE: Add manifest catch-up with BGAppRefreshTask

Phase: 1 | Spec: R-06(part)/R-34 | Priority: high | Labels: type:feature, area:ios  
Depends-on: atomic iOS manifest apply; revisioned widget snapshot issue | Inherited-context: STR-969 | Estimate: M

Register `BGAppRefreshTask` identifier `ai.hermes.app.refresh` during `application(_:didFinishLaunchingWithOptions:)`, before scheduling submissions.

The handler must:

1. Load the saved gateway URL and active manifest scope.
2. Resolve the token from Keychain.
3. Request the manifest from the plugin route.
4. Validate all pages within the available budget.
5. Apply one GRDB transaction.
6. Project the widget snapshot from that committed revision.
7. Reschedule the next opportunity.
8. Complete immediately.

Set an expiration handler that cancels the fetch, prevents partial apply, and calls `setTaskCompleted(success: false)`. Scheduling is opportunistic; `earliestBeginDate` must not be presented as a guarantee. Coalesce with an in-flight foreground or push sync.

Update `apps/ios/project.yml`, regenerate the Xcode project, and add to `Info.plist`:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
  <string>ai.hermes.app.refresh</string>
</array>
```

Add `fetch` to `UIBackgroundModes` and ensure the generated target declares Background Modes. Preserve the existing APNs and app-group entitlements. Do not add `processing`; `BGProcessingTask` belongs to Phase 2.

Do not schedule until a gateway has been successfully paired. Missing saved scope/token should complete cleanly without network access.

Acceptance criteria:

- [ ] Registration occurs at launch before any submit call.
- [ ] The task uses the same manifest client, transaction, and cursor as foreground/push sync.
- [ ] A successful run refreshes cache and widget at one revision and reschedules.
- [ ] Expiration/cancellation commits no partial page or cursor.
- [ ] Missing pairing state performs no request and completes safely.
- [ ] Concurrent triggers coalesce rather than racing database writers.
- [ ] A missed silent push is recovered by app refresh or the next foreground sync.
- [ ] `BGTaskSchedulerPermittedIdentifiers` and the `fetch` background mode exist in canonical and generated configuration.
- [ ] The implementation never promises exact execution time.
- [ ] No `BGProcessingTask`, background URLSession, or long-running maintenance is introduced.

Tests required: Inject a scheduler/task abstraction and test registration order, saved scope, Keychain failure, success, no-change, expiration, rescheduling, trigger coalescing, atomic rollback, and widget ordering. Add plist/project-generation tests and a launch integration test.

### ISSUE: Make widget snapshots revisioned and merge-safe

Phase: 1 | Spec: R-12/R-55/R-56/R-57 | Priority: high | Labels: type:fix, area:ios  
Depends-on: atomic iOS manifest apply | Inherited-context: STR-969 | Estimate: M

Replace the current process-local baseline in `WidgetSnapshotWriter.swift:26-83`. `lastWritten` may remain only as a no-op optimization after loading disk; it must never be the authoritative merge source.

Introduce the R-57 snapshot schema:

- `schema_version`
- `server_scope`
- `server_revision`
- `connection_state`
- `open_session_count`
- `active_turn_count`
- `pending_attention_count`
- `tokens_today`
- `cost_today`
- `fetched_at`
- `written_at`
- `is_stale`

Use explicit field patches—retain, set, clear—so an omitted value never clears a valid persisted value. Read the latest shared snapshot from disk before every merge. Store the v2 snapshot as an atomically replaced JSON file in the app-group container; migrate the current UserDefaults value once for backward compatibility.

Remove the pre-bootstrap destructive baseline at `AppEnvironment.swift:197-215`, or make it a retain-only connection patch after disk state has loaded. Manifest-derived counts and usage are written together after the GRDB commit. Stop deriving “active sessions” from `activeStoredId`.

Widgets must display open-session and active-turn counts separately. A connected indicator is current only when the snapshot’s connection state is connected, its revision is committed, and `fetched_at` is no more than 15 minutes old. Otherwise show a cached/stale state and relative “Last updated …” text. Widget timeline evaluation recomputes effective staleness so suspension cannot leave a green dot indefinitely.

Acceptance criteria:

- [ ] A cold process cannot erase non-null usage or counts before bootstrap.
- [ ] Unspecified fields are retained; only explicit clear operations erase values.
- [ ] Writes are atomic across app/widget processes.
- [ ] Legacy UserDefaults snapshots migrate without losing usage.
- [ ] Snapshot schema and server revision match the committed manifest.
- [ ] Open sessions, active turns, and pending attention use authoritative manifest definitions.
- [ ] Inbox, drawer, and widget expose the same revision after reconciliation.
- [ ] A suspended/stale snapshot never displays “Connected” as current.
- [ ] Both widgets show relative last-updated/stale language.
- [ ] A failed manifest transaction cannot advance widget data or revision.
- [ ] `lastWritten` is never used as a cold-process source of truth.

Tests required: Add `WidgetSnapshotWriterTests.swift` covering cold-process reset, disk merge, retain/set/clear, explicit zero versus nil, legacy migration, atomic replacement, revision ordering, failed-transaction behavior, and stale-time calculation. Add Status/Usage widget rendering tests for fresh, stale, offline, null usage, open sessions, active turns, and attention.

### ISSUE: Add scope-safe offline transcript search

Phase: 1 | Spec: R-52 | Priority: medium | Labels: type:feature, area:ios  
Depends-on: scoped cache migration; atomic manifest apply | Inherited-context: STR-969, STR-9 | Estimate: L

Current search is network-only (`SessionStore.swift:3152-3340`), although transcript bodies are already persisted in `message_row_cache`. Add a local GRDB FTS5 index keyed by actual `(serverId, profileId, sessionId, wireId/ordinal)` identity.

Use a `unicode61` tokenizer and index safe textual user, assistant, and tool content extracted from `StoredMessage`. Maintain the index in the same transaction as transcript replace/append. Explicitly remove FTS rows when a session tombstone or gateway purge deletes the corresponding cache; virtual tables cannot rely on foreign-key cascade.

Backfill existing cached message JSON in bounded batches after opening the migrated database. New transcript writes index synchronously. Persist per-scope backfill progress and expose `partial` freshness until the active scope’s cached rows are indexed.

On query:

1. Debounce as today.
2. Publish local scoped results immediately, including offline.
3. If connected, request the existing plugin/stock remote search concurrently.
4. Merge remote/global results by stable scoped session/message identity without clearing local results.
5. Preserve stable local ordering while appending or enriching remote hits.
6. Ignore stale query generations using the existing `searchGeneration` guard.
7. Opening an offline hit must target the cached row directly.

Add `CacheStore.purgeGateway(serverId:)` that deletes sessions, messages, FTS rows, attention, turns, heads, cursors, last-opened data, and widget source state for that gateway. Wire it to the future Forget Gateway transaction, not the existing non-destructive Disconnect action.

Remote results outside the cached transcript window may still require STR-9 around-route paging; that does not block offline results for locally cached rows.

Acceptance criteria:

- [ ] Search returns cached transcript hits without a network client.
- [ ] Local results appear before remote search completes.
- [ ] Remote results merge without flashing the local list empty.
- [ ] Results never cross gateway or actual-profile identity.
- [ ] Same session IDs in two profiles remain distinguishable.
- [ ] Transcript replace/append, manifest tombstones, and gateway purge keep FTS consistent.
- [ ] Existing caches backfill incrementally without blocking first paint.
- [ ] Search reports partial while backfill is incomplete.
- [ ] Forget Gateway’s purge primitive removes every searchable row for that gateway.
- [ ] Ordinary Disconnect does not silently erase offline search data.
- [ ] Opening after a week permits immediate offline search over cached content.

Tests required: Add `OfflineSearchTests.swift` for indexing, role filters, Unicode/diacritics, scope isolation, duplicate IDs, replace/append, tombstone cleanup, backfill resume, partial state, stale-query cancellation, local-first remote merge, offline opening, and gateway purge. Retain the existing `PluginSearchTests.swift` and `SearchPaginationTests.swift` remote-path coverage.

## DEPENDENCY ORDER

1. Land and re-audit PR #147 / STR-1208.
2. Migrate cache identity.
3. Build the plugin sync-manifest endpoint in parallel with the cache migration.
4. Add atomic iOS manifest apply.
5. Build cached-shell freshness UI and widget projection.
6. Add server background invalidations.
7. Add iOS silent-push handling.
8. Add `BGAppRefreshTask`.
9. Add scoped offline FTS on the migrated schema.

## UNSATISFIABLE OR EXTERNALLY BLOCKED CLAUSES

- The requested output file could not be written. The managed workspace permits writes only under `/Volumes/MainData/Developer/products/hermes-mobile`, while `/Users/abbhinnav/Developer/products/hermes-loop/docs/mobile-foundation/lane-outputs/lane-f-phase1-issues.md` is outside that root. The required `apply_patch` write was rejected, and approval escalation is disabled. No substitute file was created because the user authorized only the requested output path.
- PR #147’s actual diff could not be verified because GitHub was unreachable and no local PR ref/object exists. Before implementation, run `gh pr diff 147 --repo abhibansal-sg/hermes-mobile` after access is restored and reconcile its exact endpoint, cursor, tombstone, and cache changes against this contract.
- R-46 cannot literally change primary keys for outbox and panel tables in Phase 1 because those tables do not exist and belong to later phases. Creating unused placeholders would violate the repository’s prohibition on speculative infrastructure.
- R-43’s durable no-runtime sending cannot be completed without the Phase-2 SQLite outbox and server idempotency work.
- R-70 cannot cover all listed remote panels in Phase 1 because several lack resource revisions; this draft limits Phase 1 to manifest-backed shell, Sessions, Inbox, and Widgets.

LANE_RESULT: done_with_concerns Complete contract and nine build-ready Phase-1 drafts produced; exact file write and direct PR #147 inspection were blocked by the execution environment.