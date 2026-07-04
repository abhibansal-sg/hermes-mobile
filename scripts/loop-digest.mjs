#!/usr/bin/env node
/**
 * loop-digest.mjs — READ-ONLY one-screen status board for the Hermes autonomous loop.
 *
 * The "measured output" rung of the governor: a scheduled, side-effect-free summary so
 * you can step back and read STATUS instead of watching the loop. It reads three sources,
 * mutates nothing:
 *   • Linear (GraphQL) — the Hermes Mobile — Engineering board: open issues by state,
 *     what's blocked:needs-human, recent Done (velocity).
 *   • ~/bin/cc-usage  — budget headroom (the loop's pacing signal).
 *   • .claude/loops/governor.json — kill-switch / shadow-mode / active loops.
 *
 *   node scripts/loop-digest.mjs            # human one-screen board
 *   node scripts/loop-digest.mjs --json     # machine-readable
 *
 * Auth: LINEAR_API_KEY env (a personal API key). Without it, the Linear section is
 * skipped (the governor + budget sections still print) — never fails the whole digest.
 * Read-only: only GraphQL queries, no mutations. Safe to schedule as a Routine.
 */

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';
import { execSync } from 'node:child_process';

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const GOV = path.join(HERE, '..', '.claude', 'loops', 'governor.json');
const TEAM_KEY = 'ABH';
const PROJECT_NAME = 'Hermes Mobile — Engineering';
const asJson = process.argv.includes('--json');

function govState() {
  try {
    const g = JSON.parse(fs.readFileSync(GOV, 'utf8'));
    return {
      enabled: g.enabled, shadow_mode: g.shadow_mode,
      active_action_loops: g.concurrency_state?.active_action_loops ?? [],
      caps: g.caps,
    };
  } catch { return null; }
}

function headroom() {
  try {
    const out = execSync('~/bin/cc-usage status', { encoding: 'utf8', shell: '/bin/zsh', timeout: 8000 });
    const hs = [...out.matchAll(/headroom\s+(\d+)/g)].map(m => Number(m[1]));
    return { worst: hs.length ? Math.min(...hs) : null, raw: out.trim().split('\n').slice(0, 4) };
  } catch { return { worst: null, raw: ['cc-usage unavailable'] }; }
}

async function linear(query) {
  const key = process.env.LINEAR_API_KEY;
  if (!key) return null;
  const res = await fetch('https://api.linear.app/graphql', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: key },
    body: JSON.stringify({ query }),
  });
  if (!res.ok) throw new Error(`Linear ${res.status}: ${await res.text().catch(() => '')}`);
  const j = await res.json();
  if (j.errors) throw new Error(`Linear GQL: ${JSON.stringify(j.errors)}`);
  return j.data;
}

async function board() {
  // Lean query: open issues (state + identifier + a couple labels), no descriptions.
  const data = await linear(`{
    issues(first: 100, filter: {
      team: { key: { eq: "${TEAM_KEY}" } },
      project: { name: { eq: "${PROJECT_NAME}" } }
    }, orderBy: updatedAt) {
      nodes {
        identifier title updatedAt
        state { name type }
        labels { nodes { name } }
      }
    }
  }`);
  if (!data) return null;
  // Blocked-human queue: TEAM-WIDE (no project filter — fenced filings land outside
  // the project too) and on the CORRECT label. The old query used the stale label
  // name 'blocked:needs-human' + project scope, which made this section blind while
  // 8 items silted (found 2026-07-04 power session).
  const bh = await linear(`{
    issues(first: 50, filter: {
      team: { key: { eq: "${TEAM_KEY}" } },
      labels: { name: { eq: "loop:blocked-human" } },
      state: { type: { nin: ["completed", "canceled"] } }
    }) {
      nodes {
        identifier title createdAt priority
        labels { nodes { name } }
      }
    }
  }`);
  const now = Date.now();
  const blocked = (bh?.issues?.nodes ?? []).map(n => {
    const ageDays = (now - new Date(n.createdAt).getTime()) / 86400000;
    const labels = (n.labels?.nodes ?? []).map(l => l.name);
    return {
      id: n.identifier, title: n.title, ageDays,
      priority: n.priority ?? 9,
      approved: labels.includes('fence:approved'),
    };
  }).sort((a, b) => (a.priority - b.priority) || (b.ageDays - a.ageDays));
  const nodes = data.issues.nodes;
  const byType = {};
  const recentDone = [];
  for (const n of nodes) {
    const t = n.state.type; // backlog|unstarted|started|completed|canceled
    byType[t] = (byType[t] || 0) + 1;
    if (t === 'completed') recentDone.push({ id: n.identifier, title: n.title, at: n.updatedAt });
  }
  recentDone.sort((a, b) => (a.at < b.at ? 1 : -1));
  // open = not completed/canceled
  const open = nodes.filter(n => !['completed', 'canceled'].includes(n.state.type));
  return {
    counts: {
      backlog: byType.backlog || 0,
      todo: byType.unstarted || 0,
      in_progress: byType.started || 0,
      done_total: byType.completed || 0,
    },
    open: open.map(n => ({ id: n.identifier, title: n.title, state: n.state.name,
                           labels: (n.labels?.nodes ?? []).map(l => l.name) })),
    blocked,
    recentDone: recentDone.slice(0, 6),
  };
}

function line(s = '') { process.stdout.write(s + '\n'); }

(async () => {
  const gov = govState();
  const hr = headroom();
  let b = null, linearErr = null;
  try { b = await board(); } catch (e) { linearErr = e.message; }

  if (asJson) {
    line(JSON.stringify({ governor: gov, headroom: hr.worst, board: b, linearErr }, null, 2));
    return;
  }

  line('────────────────────────────────────────────────────────');
  line(' HERMES LOOP — DAILY DIGEST (read-only)');
  line('────────────────────────────────────────────────────────');
  // Governor
  if (gov) {
    const ks = gov.enabled ? 'ARMED' : 'DISABLED (kill switch on)';
    line(` Governor: ${ks} | shadow_mode=${gov.shadow_mode} | active loops: ${gov.active_action_loops.join(', ') || '(none)'}`);
    line(`   caps: ≤${gov.caps.retries_per_stage} retry, ≤${gov.caps.max_iterations_per_cycle} iters/cycle, ${gov.caps.min_cc_usage_headroom_pct}% headroom floor, ${gov.caps.max_concurrent_action_loops} action-loop`);
  } else line(' Governor: (governor.json unreadable)');
  // Budget
  line(` Budget: worst headroom ${hr.worst ?? '?'}%  ${hr.worst != null && gov ? (hr.worst >= gov.caps.min_cc_usage_headroom_pct ? '(loops may run)' : '(below floor → loops defer)') : ''}`);
  line('────────────────────────────────────────────────────────');
  // Board
  if (b) {
    const c = b.counts;
    line(` Board (${PROJECT_NAME}):`);
    line(`   open: ${c.backlog} backlog · ${c.todo} todo · ${c.in_progress} in-progress    | done: ${c.done_total}`);
    if (b.blocked.length) {
      line(` ⚠ AWAITING ABHI (loop:blocked-human): ${b.blocked.length}`);
      b.blocked.forEach(x => {
        const age = x.ageDays >= 2 ? `🔴 ${x.ageDays.toFixed(0)}d` : `${x.ageDays.toFixed(1)}d`;
        const st = x.approved ? 'approved→in-pipeline' : 'NEEDS VERDICT';
        line(`     • ${x.id} p${x.priority} [${age}] (${st}) ${x.title.slice(0, 55)}`);
      });
      const needing = b.blocked.filter(x => !x.approved);
      if (needing.length) line(`   → ${needing.length} awaiting your verdict: say "approve <id>" / "park <id>" to Hermes on any surface.`);
    }
    else line(' ✓ nothing awaiting Abhi (loop:blocked-human empty)');
    if (b.open.length) {
      line(' Open issues:');
      b.open.slice(0, 12).forEach(o => line(`     ${o.id}  [${o.state}]  ${o.title.slice(0, 60)}`));
      if (b.open.length > 12) line(`     … and ${b.open.length - 12} more`);
    }
    if (b.recentDone.length) {
      line(' Recently Done:');
      b.recentDone.forEach(d => line(`     ${d.id}  ${d.title.slice(0, 60)}`));
    }
  } else {
    line(` Board: ${linearErr ? 'ERROR — ' + linearErr : 'skipped (set LINEAR_API_KEY to enable)'}`);
  }
  line('────────────────────────────────────────────────────────');
})();
