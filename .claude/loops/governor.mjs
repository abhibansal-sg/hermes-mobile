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
 *   attempts --current N                 exit 31 if N would exceed retries_per_stage (cap),
 *                                          else 0.
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

function arg(name, def = null) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? (process.argv[i + 1] ?? true) : def;
}
function has(flag) { return process.argv.includes(flag); }

// Headroom: read `cc-usage status`, parse the WORST headroom %. Conservative: if we
// can't read it, treat as 0 (fail closed → don't start a cycle on an unknown budget).
function headroomPct() {
  try {
    const out = execSync('~/bin/cc-usage status', { encoding: 'utf8', shell: '/bin/zsh', timeout: 8000 });
    const hs = [...out.matchAll(/headroom\s+(\d+)/g)].map(m => Number(m[1]));
    return hs.length ? Math.min(...hs) : 0;
  } catch { return 0; }
}

const cfg = load();
const cmd = process.argv[2];

switch (cmd) {
  case 'preflight': {
    const loop = arg('--loop', 'loop');
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
      const active = cfg.concurrency_state?.active_action_loops ?? [];
      const cap = cfg.caps?.max_concurrent_action_loops ?? 1;
      const others = active.filter(l => l !== loop);
      if (others.length >= cap) {
        console.error(`[governor] concurrency cap ${cap} reached (active: ${others.join(', ')}) — ${loop} waits.`);
        process.exit(12);
      }
    }
    console.error(`[governor] preflight OK for ${loop} (enabled, headroom ${have}%≥${need}%${isAction ? ', under concurrency cap' : ''}).`);
    process.exit(0);
  }

  case 'spin': {
    const prev = String(arg('--prev', ''));
    const cur  = String(arg('--cur', ''));
    if (prev && cur && prev === cur) {
      console.error(`[governor] SPIN: identical failure signature twice ("${cur}") → STOP + escalate (never retry the same approach).`);
      process.exit(20);
    }
    console.error('[governor] no spin (signatures differ or first attempt).');
    process.exit(0);
  }

  case 'evidence': {
    const kind = String(arg('--kind', ''));
    const artifact = arg('--artifact', null);
    const accepted = cfg.evidence_gate?.accepted_kinds ?? [];
    if (!cfg.evidence_gate?.required) { console.error('[governor] evidence gate off.'); process.exit(0); }
    if (!accepted.includes(kind)) {
      console.error(`[governor] NO GREEN: "${kind}" is not hard evidence. Accepted: ${accepted.join(', ')}.`);
      process.exit(30);
    }
    if (!artifact) {
      console.error(`[governor] NO GREEN: evidence kind "${kind}" given but no artifact value attached.`);
      process.exit(30);
    }
    console.error(`[governor] evidence OK: ${kind} = ${artifact}`);
    process.exit(0);
  }

  case 'attempts': {
    const current = Number(arg('--current', '0'));
    const cap = cfg.caps?.retries_per_stage ?? 1;
    // attempts allowed = 1 initial + retries_per_stage. exceed → block.
    if (current > cap) {
      console.error(`[governor] attempt ${current} exceeds retries_per_stage ${cap} → set blocked:needs-human + escalate.`);
      process.exit(31);
    }
    console.error(`[governor] attempt ${current} within cap (${cap} retries).`);
    process.exit(0);
  }

  case 'register': {
    const loop = String(arg('--loop', ''));
    if (!loop) { console.error('[governor] register needs --loop NAME'); process.exit(2); }
    cfg.concurrency_state ??= { active_action_loops: [] };
    cfg.concurrency_state.active_action_loops ??= [];
    if (!cfg.concurrency_state.active_action_loops.includes(loop))
      cfg.concurrency_state.active_action_loops.push(loop);
    save(cfg);
    console.error(`[governor] registered ${loop}. active: ${cfg.concurrency_state.active_action_loops.join(', ')}`);
    process.exit(0);
  }
  case 'deregister': {
    const loop = String(arg('--loop', ''));
    cfg.concurrency_state ??= { active_action_loops: [] };
    cfg.concurrency_state.active_action_loops =
      (cfg.concurrency_state.active_action_loops ?? []).filter(l => l !== loop);
    save(cfg);
    console.error(`[governor] deregistered ${loop}. active: ${cfg.concurrency_state.active_action_loops.join(', ') || '(none)'}`);
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
    console.log(JSON.stringify({
      enabled: cfg.enabled,
      shadow_mode: cfg.shadow_mode,
      caps: cfg.caps,
      active_action_loops: cfg.concurrency_state?.active_action_loops ?? [],
      headroom_pct_now: headroomPct(),
    }, null, 2));
    process.exit(0);
  }

  default:
    console.error('usage: governor.mjs {preflight|spin|evidence|attempts|register|deregister|kill|arm|status}');
    process.exit(2);
}
