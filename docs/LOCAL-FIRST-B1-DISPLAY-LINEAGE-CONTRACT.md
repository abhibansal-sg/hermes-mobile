# B1 Display-Lineage and Turn-Ledger Contract

**Status:** Implemented generic SessionDB display lineage and authoritative
turn-ledger prerequisites. Compact projection publication remains gated on the
bounded projector and historical golden fixtures.

## Contract

SessionDB schema v22 separates mutable model-context rows from stable display
identity:

- each non-synthetic source row receives a stable `display_origin_id`;
- `message_display_origins` owns the current canonical physical row and display
  versus rewind state for that origin;
- `sessions.display_generation` advances on compaction while
  `sessions.display_revision` advances on display-affecting appends, rewrites,
  rewinds, and restores;
- compaction copies preserve their origin but cannot become a second canonical
  display row;
- compressed summaries, TODO snapshots, and defensive continuation markers are
  `synthetic_no_display` and have no display origin;
- rewind and replacement retain revisioned origin tombstones;
- `get_display_messages` and `get_display_tombstones` are public bounded reads
  and do not expose a private SQLite connection; and
- pre-v22 sessions with any already-compacted rows fail closed with
  `display_lineage_complete = 0` because their missing lineage cannot be
  reconstructed honestly.

The underscore-prefixed lineage fields carried inside in-process conversation
messages are stripped by the existing provider wire sanitizers. They do not
change the system prompt, prior model content, role alternation, or prompt-cache
prefix.

## Proven cases

The SessionDB behavior tests cover:

- bounded newest/older origin paging;
- two compaction generations with every original displayed exactly once;
- synthetic summary exclusion;
- rewind after compaction and explicit tombstones;
- restore after rewind;
- replace/retry retention without duplicate origins; and
- fail-closed migration for an ambiguous already-compacted legacy session.

Gateway, ACP, compression, transcript-delta, and SessionDB regressions run
against the same implementation.

## Authoritative turn ledger

SessionDB schemas v23-v24 add a public, bounded ledger independent of mutable model
context:

- `session_turns` owns the opaque turn ID, queued/running/terminal state,
  acceptance/start/terminal timestamps, and nullable terminal display origin;
- `session_turn_inputs` preserves every committed prompt, steering input,
  interrupt-and-replace prompt, and queued follow-up in stable ordinal order;
- a `client_message_id` can identify only one scoped turn input;
- exact receipt replay is idempotent, while an input ID reused with different
  content fails closed;
- a terminal turn rejects new inputs and contradictory terminal outcomes; and
- bounded turn/input reads never enumerate the raw tool-heavy transcript.
- `session_turn_operations` persists only safe operation identity, category,
  label, state, and timing; tool arguments, results, terminal output, and
  reasoning never enter this projection ledger; and
- per-session ledger coverage is explicit. A newly created empty session can
  become complete immediately, while resumed, branched, imported, or otherwise
  historical sessions remain honestly partial until checkpointed backfill.

The TUI gateway reserves and persists the turn before acknowledging a mobile
prompt receipt. The receipt, inflight snapshot, lifecycle frames, and terminal
ledger transition carry the same authoritative `turn_id`. Legacy requests
without the receipt capability preserve their prior response shape.

The iOS Work database now retains a receipt-bearing job in the durable
`accepted` (accepted-awaiting-projection) state. It can complete only after the
reconstructible GRDB projection commits the same verified authority scope,
`client_message_id`, and `turn_id`. Restart recovery is idempotent and the
optimistic overlay cannot disappear in the cross-database crash window.

## Bounded projection reader

The plugin now exposes a schema-v1 compact turn page backed only by the bounded
turn/input/operation ledgers and stable display-origin lookup. Cursors bind to
the display revision, equal timestamps cannot skip a turn, terminal content is
accepted only from the durable terminal display origin, and rewind tombstones
dominate delayed pages. The iOS cache schema v7 applies those pages atomically
and reads only the requested compact turn window.

The capability must still remain unadvertised until checkpointed historical
backfill and real historical golden fixtures prove complete coverage.
Historical grouping and final-response inference remain null/fail-closed when
the durable ledger or display lineage cannot prove them.
