#!/usr/bin/env node
/**
 * governor.mjs — EXECUTABLE enforcement of .claude/loops/governor.json.
 *
 * GOVERNOR.md is the runbook; governor.json is the numbers; THIS is the gate a loop
 * actually calls each cycle so the rules are enforced by code, not by good intentions.
 * Read-only w.r.t. the repo (only reads governor.json + shells `cc-usage`); the one
 * mutable bit of state is concurrency registration, written back into governor.json's
 * `concurrency_state` so the cap is real across processes.
 *
 * Subcommands (exit codes are the contract a loop branches on):
 *   preflight [--loop NAME] [--action]   gate the START of a cycle. Checks, in order:
 *                                          kill switch (enabled), cc-usage headroom,
 *                                          and (for --action loops) the concurrency cap.
 *                                          exit 0 = proceed; 10 = disabled; 11 = low headroom;
 *                                          12 = concurrency cap; 2 = config error.
 *   spin --prev SIG --cur SIG            exit 20 if the two failure signatures match
 *                                          (spin → STOP), else 0. "Never retry twice."
 *   evidence --kind KIND [--artifact X]  exit 0 if KIND is an accepted hard-evidence kind
 *                                          AND an artifact value is present; else 30 (no
 *                                          green without evidence).
 *   attempts --current N                 N is the 1-indexed attempt number. exit 31 if N
 *                                          exceeds 1 initial + retries_per_stage retries
 *                                          (i.e. N > cap+1), else 0.
 *   register --loop NAME                 add NAME to active_action_loops (after a passed
 *                                          preflight); deregister --loop NAME removes it.
 *   status                               print the live governor state (enabled, shadow,
 *                                          caps, active loops, headroom) as JSON.
 *   kill / arm                           flip enabled false/true (the kill switch). `kill`
 *                                          is always safe; `arm` only sets it true.
 *
 * NEVER bypasses guard.sh (that PreToolUse hook is the independent 5% backstop).
 */

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';
import { execSync } from 'node:child_process';

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const CONFIG = path.join(HERE, 'governor.json');

function load() {
  try { return JSON.parse(fs.readFileSync(CONFIG, 'utf8')); }
  catch (e) { console.error(`[governor] cannot read ${CONFIG}: ${e.message}`); process.exit(2); }
}
function save(cfg) { fs.writeFileSync(CONFIG, JSON.stringify(cfg, null, 2) + '\n'); }

// Sentinel returned by arg() when a flag is present but has NO value (it's the
// last token, or the next token is itself a flag like `--foo`). Distinct from a
// real string value of "true" — callers (e.g. the evidence gate) must be able to
// tell "flag present, no value attached" from "the value happens to be 'true'".
const FLAG_NO_VALUE = Symbol('flag-present-no-value');

function arg(name, def = null) {
  const i = process.argv.indexOf(name);
  if (i < 0) return def;
  const next = process.argv[i + 1];
  // No following token, or the following token is another flag → value-less flag.
  if (next === undefined || (typeof next === 'string' && next.startsWith('--'))) return FLAG_NO_VALUE;
  return next;
}
function has(flag) { return process.argv.includes(flag); }

// True iff arg() returned the value-less-flag sentinel (flag present, no value).
function isFlagNoValue(v) { return v === FLAG_NO_VALUE; }
// Coerce an arg() result to a plain string, mapping the no-value sentinel and
// null/undefined to a caller-supplied fallback (default empty string).
function strOr(v, fb = '') { return (v === FLAG_NO_VALUE || v == null) ? fb : String(v); }

// Headroom: read `cc-usage status`, parse the WORST headroom %. Conservative: if we
// can't read it, treat as 0 (fail closed → don't start a cycle on an unknown budget).
function headroomPct() {
  try {
    const out = execSync('~/bin/cc-usage status', { encoding: 'utf8', shell: '/bin/zsh', timeout: 8000 });
    const hs = [...out.matchAll(/headroom\s+(\d+)/g)].map(m => Number(m[1]));
    return hs.length ? Math.min(...hs) : 0;
  } catch { return 0; }
}

// ── Concurrency state: instance-keyed, backward-tolerant ──────────────────────
// active_action_loops holds one entry PER RUNNING INSTANCE (not per loop NAME), so
// two same-named loops each occupy a distinct slot and the cap binds for them too.
// Entries are { id, ts } where id is a unique instance id (`${loop}#${pid}` or any
// uuid the caller passes) and ts is the ISO time of (re)registration, used to reap a
// slot leaked by a signal-killed loop. Legacy bare-string entries (e.g. "auto") are
// tolerated on read and migrated to {id, ts} on the next write.
function normalizeActive(raw) {
  if (!Array.isArray(raw)) return [];
  return raw.map(e => {
    if (typeof e === 'string') return { id: e, ts: null };       // legacy bare string
    if (e && typeof e === 'object' && typeof e.id === 'string')
      return { id: e.id, ts: typeof e.ts === 'string' ? e.ts : null };
    return null;
  }).filter(Boolean);
}

// Drop entries older than the heartbeat silence window — a slot leaked by a
// SIGTERM/SIGINT-killed loop self-heals here without needing a perfect signal
// handler. A legacy bare-string (ts:null) has no timestamp → it is NOT reaped
// (we can't prove it's stale; the live "auto" loop must survive).
function reapStale(entries, silenceMin) {
  if (!silenceMin || silenceMin <= 0) return entries;
  const cutoff = Date.now() - silenceMin * 60_000;
  return entries.filter(e => {
    if (e.ts == null) return true;            // legacy / no timestamp → keep
    const t = Date.parse(e.ts);
    if (Number.isNaN(t)) return true;         // unparseable → keep (fail safe)
    return t >= cutoff;
  });
}

const cfg = load();
const cmd = process.argv[2];

switch (cmd) {
  case 'preflight': {
    const loop = strOr(arg('--loop', 'loop'), 'loop');
    // Identify THIS process by its unique instance id (defaults to the loop name
    // when no --instance is supplied, preserving old single-instance behavior).
    const instance = strOr(arg('--instance', loop), loop);
    const isAction = has('--action');
    if (!cfg.enabled) {
      console.error(`[governor] DISABLED (kill switch). ${loop} exits without working.`);
      process.exit(10);
    }
    const need = cfg.caps?.min_cc_usage_headroom_pct ?? 0;
    const have = headroomPct();
    if (have < need) {
      console.error(`[governor] headroom ${have}% < required ${need}% — defer ${loop}.`);
      process.exit(11);
    }
    if (isAction) {
      const silenceMin = cfg.heartbeat?.silence_alert_min ?? 0;
      const active = reapStale(normalizeActive(cfg.concurrency_state?.active_action_loops), silenceMin);
      const cap = cfg.caps?.max_concurrent_action_loops ?? 1;
      // Self-exclude by INSTANCE id (not loop name): every OTHER running instance
      // counts toward the cap, even one sharing this loop's name.
      const others = active.filter(e => e.id !== instance);
      if (others.length >= cap) {
        console.error(`[governor] concurrency cap ${cap} reached (active: ${others.map(e => e.id).join(', ')}) — ${loop} (${instance}) waits.`);
        process.exit(12);
      }
    }
    console.error(`[governor] preflight OK for ${loop} (${instance}) (enabled, headroom ${have}%≥${need}%${isAction ? ', under concurrency cap' : ''}).`);
    process.exit(0);
  }

  case 'spin': {
    const prev = strOr(arg('--prev', ''));
    const cur  = strOr(arg('--cur', ''));
    if (prev && cur && prev === cur) {
      console.error(`[governor] SPIN: identical failure signature twice ("${cur}") → STOP + escalate (never retry the same approach).`);
      process.exit(20);
    }
    console.error('[governor] no spin (signatures differ or first attempt).');
    process.exit(0);
  }

  case 'evidence': {
    // Disambiguate at PARSE time: arg() returns the FLAG_NO_VALUE sentinel for a
    // value-less flag (e.g. a trailing `--artifact`), so we can tell "flag present,
    // no value" (reject — no real evidence) from a genuine value that happens to be
    // the string "true" (a legitimate artifact, e.g. an exit-code/boolean result).
    const rawKind = arg('--kind', '');
    const rawArtifact = arg('--artifact', '');
    const kindMissing = isFlagNoValue(rawKind);
    const artifactMissing = isFlagNoValue(rawArtifact);
    const kind = strOr(rawKind).trim();
    const artifact = strOr(rawArtifact).trim();
    const accepted = cfg.evidence_gate?.accepted_kinds ?? [];
    if (!cfg.evidence_gate?.required) { console.error('[governor] evidence gate off.'); process.exit(0); }
    if (kindMissing || !kind) {
      console.error(`[governor] NO GREEN: --kind requires a value. Accepted: ${accepted.join(', ')}.`);
      process.exit(30);
    }
    if (!accepted.includes(kind)) {
      console.error(`[governor] NO GREEN: "${kind}" is not hard evidence. Accepted: ${accepted.join(', ')}.`);
      process.exit(30);
    }
    if (artifactMissing || !artifact) {
      console.error(`[governor] NO GREEN: evidence kind "${kind}" given but no artifact value attached.`);
      process.exit(30);
    }
    console.error(`[governor] evidence OK: ${kind} = ${artifact}`);
    process.exit(0);
  }

  case 'attempts': {
    const current = Number(strOr(arg('--current', '0'), '0'));
    const cap = cfg.caps?.retries_per_stage ?? 1;
    // --current is the 1-indexed attempt number. Allowed attempts = 1 initial +
    // retries_per_stage retries → the highest allowed attempt number is cap + 1.
    // e.g. retries_per_stage=1: attempt 1 (initial) PASS, attempt 2 (the retry)
    // PASS, attempt 3 BLOCK. Block only once current exceeds (cap + 1).
    if (current > cap + 1) {
      console.error(`[governor] attempt ${current} exceeds 1 initial + ${cap} retries (max attempt ${cap + 1}) → set blocked:needs-human + escalate.`);
      process.exit(31);
    }
    console.error(`[governor] attempt ${current} within cap (1 initial + ${cap} retries = ${cap + 1} attempts).`);
    process.exit(0);
  }

  case 'register': {
    const loop = strOr(arg('--loop', ''));
    if (!loop) { console.error('[governor] register needs --loop NAME'); process.exit(2); }
    // Register by unique INSTANCE id (defaults to the loop name for old callers).
    const instance = strOr(arg('--instance', loop), loop);
    const silenceMin = cfg.heartbeat?.silence_alert_min ?? 0;
    cfg.concurrency_state ??= { active_action_loops: [] };
    // Migrate legacy bare strings to {id, ts} on write + reap any leaked stale slot.
    let active = reapStale(normalizeActive(cfg.concurrency_state.active_action_loops), silenceMin);
    // Drop a prior entry with the SAME instance id, then add a fresh timestamped one
    // (so a re-register refreshes the heartbeat ts rather than duplicating).
    active = active.filter(e => e.id !== instance);
    active.push({ id: instance, ts: new Date().toISOString() });
    cfg.concurrency_state.active_action_loops = active;
    save(cfg);
    console.error(`[governor] registered ${loop} (${instance}). active: ${active.map(e => e.id).join(', ')}`);
    process.exit(0);
  }
  case 'deregister': {
    const loop = strOr(arg('--loop', ''));
    // Remove ONLY this caller's instance id — never every entry sharing the name.
    const instance = strOr(arg('--instance', loop), loop);
    const silenceMin = cfg.heartbeat?.silence_alert_min ?? 0;
    cfg.concurrency_state ??= { active_action_loops: [] };
    const active = reapStale(normalizeActive(cfg.concurrency_state.active_action_loops), silenceMin)
      .filter(e => e.id !== instance);
    cfg.concurrency_state.active_action_loops = active;
    save(cfg);
    console.error(`[governor] deregistered ${loop} (${instance}). active: ${active.map(e => e.id).join(', ') || '(none)'}`);
    process.exit(0);
  }

  case 'kill': {
    cfg.enabled = false; save(cfg);
    console.error('[governor] KILL SWITCH ENGAGED — enabled=false. All loops will exit on next preflight.');
    process.exit(0);
  }
  case 'arm': {
    cfg.enabled = true; save(cfg);
    console.error('[governor] ARMED — enabled=true. Loops may run (still gated by headroom/concurrency/evidence).');
    process.exit(0);
  }

  case 'status': {
    const silenceMin = cfg.heartbeat?.silence_alert_min ?? 0;
    const norm = normalizeActive(cfg.concurrency_state?.active_action_loops);
    const live = reapStale(norm, silenceMin);
    console.log(JSON.stringify({
      enabled: cfg.enabled,
      shadow_mode: cfg.shadow_mode,
      caps: cfg.caps,
      active_action_loops: norm,                       // as stored (incl. any stale)
      active_action_loops_live: live.map(e => e.id),    // after stale-reap (counts toward cap)
      headroom_pct_now: headroomPct(),
    }, null, 2));
    process.exit(0);
  }

  default:
    console.error('usage: governor.mjs {preflight|spin|evidence|attempts|register|deregister|kill|arm|status}');
    process.exit(2);
}
