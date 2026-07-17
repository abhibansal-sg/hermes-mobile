# B1 Display-Lineage Contract

**Status:** Implemented generic SessionDB prerequisite; turn-ledger proof remains
the next B1 gate.

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

## Remaining B1 gate

This prerequisite deliberately does not invent turn boundaries. B1 remains
closed until the generic durable turn ledger proves prompt, steering,
interrupt-and-replace, queued follow-up, terminal-message identity, and exact
turn timing. The plugin must not advertise `turn_projection: 1` before that
second proof passes.
