#!/usr/bin/env node
/**
 * pipeline-status.mjs — READ-ONLY conveyor dashboard for the autonomous dev loop.
 *
 * Prints the whole buffered-basket pipeline at a glance: which wave is in which
 * basket, what's parked on Abhi, what's throttled by a WIP cap, and the live
 * Kanban execution state. It only READS (PROJECT.yaml, governor.json,
 * `hermes kanban list`, and the ASC build state via asc-poll). It NEVER mutates
 * anything — no card transitions, no ship, no git. Sibling to asc-poll.mjs.
 *
 *   node scripts/pipeline-status.mjs           # full dashboard
 *   node scripts/pipeline-status.mjs --json     # machine-readable snapshot
 *   node scripts/pipeline-status.mjs --no-asc    # skip the ASC network call
 *
 * Exit codes:
 *   0  = printed OK
 *   2  = a data source could not be read (prints what it could)
 *
 * The contract this visualizes lives in docs/autonomous/wave-pipeline.md.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import yaml from 'js-yaml';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(__dirname, '..');
const PROJECT_YAML = path.join(REPO, 'docs/autonomous/PROJECT.yaml');
const GOVERNOR_JSON = path.join(REPO, '.claude/loops/governor.json');
const BOARD = 'hermes-mobile';

const args = process.argv.slice(2);
const JSON_OUT = args.includes('--json');
const NO_ASC = args.includes('--no-asc');

// ─── colors (skip when piping) ───────────────────────────────────────────────
const tty = process.stdout.isTTY;
const c = (code, s) => (tty ? `\x1b[${code}m${s}\x1b[0m` : s);
const dim = (s) => c('2', s);
const bold = (s) => c('1', s);
const green = (s) => c('32', s);
const yellow = (s) => c('33', s);
const red = (s) => c('31', s);
const cyan = (s) => c('36', s);

// ─── safe readers ────────────────────────────────────────────────────────────
let sawError = false;
function readYaml(p) {
  try { return yaml.load(fs.readFileSync(p, 'utf8')); }
  catch (e) { sawError = true; return { __error: e.message }; }
}
function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch (e) { sawError = true; return { __error: e.message }; }
}
function kanbanList() {
  try {
    const out = execFileSync('hermes', ['kanban', '--board', BOARD, 'list', '--json'],
      { encoding: 'utf8', timeout: 25000, stdio: ['ignore', 'pipe', 'ignore'] });
    return JSON.parse(out);
  } catch {
    // fall back to non-json (older CLIs) — return empty, we degrade gracefully
    return null;
  }
}
function ascNewest() {
  if (NO_ASC) return null;
  try {
    const out = execFileSync('node', [path.join(__dirname, 'asc-poll.mjs'), '--once', '--json'],
      { encoding: 'utf8', timeout: 60000, stdio: ['ignore', 'pipe', 'ignore'] });
    const line = out.trim().split('\n').filter(Boolean).pop();
    return JSON.parse(line);
  } catch { return null; }
}

// ─── gather ──────────────────────────────────────────────────────────────────
const project = readYaml(PROJECT_YAML);
const governor = readJson(GOVERNOR_JSON);
const planning = project?.planning || {};
const ledger = planning.wave_ledger || [];
const activeWave = planning.active_execution_wave || '(none)';
const stages = planning.wave_stages || [];
const pipeline = governor?.pipeline || {};
const wipCaps = pipeline.wip_caps || {};
const roster = governor?.roster?.profiles || {};

const kanban = kanbanList();
const asc = ascNewest();

// ─── derive basket occupancy ─────────────────────────────────────────────────
// Map wave stages onto the 6 baskets.
const STAGE_TO_BASKET = {
  planning: 1,
  approved: 1,
  building: 2,
  'awaiting-ship': 2,
  'awaiting-device-verify': 4,
  verified: 5,
};
const BASKETS = [
  { n: 0, name: 'INTAKE',   note: 'scout → Linear Backlog' },
  { n: 1, name: 'PLAN',     note: 'architect assembles wave N+1' },
  { n: 2, name: 'BUILD',    note: 'engineer→worker; verifier; reviewer' },
  { n: 3, name: 'SHIP',     note: 'archive+upload → TestFlight (Abhi-gated)' },
  { n: 4, name: 'VERIFY',   note: "Abhi smoke-tests on the phone (async)" },
  { n: 5, name: 'FEEDBACK', note: 'pass→close; fail→new fix issues→[0]' },
];

const wavesByBasket = {};
for (const w of ledger) {
  const b = STAGE_TO_BASKET[w.stage] ?? '?';
  (wavesByBasket[b] ||= []).push(w);
}

// shipped-but-unverified count → drives the SHIP throttle
const shippedUnverified = ledger.filter(w => w.stage === 'awaiting-device-verify').length;
const shipCap = wipCaps.shipped_unverified_builds ?? Infinity;
const shipThrottled = shippedUnverified >= shipCap;

// parking lot: anything awaiting Abhi
const parkedOnAbhi = ledger
  .filter(w => w.stage === 'awaiting-device-verify' || w.stage === 'awaiting-ship')
  .map(w => ({ wave: w.label, build_no: w.build_no, waiting_for:
    w.stage === 'awaiting-ship' ? 'Abhi: approve TestFlight upload' : 'Abhi: device-verify on phone' }));

// kanban active (anything not done/archived)
let activeCards = [];
if (Array.isArray(kanban)) {
  activeCards = kanban.filter(t => !['done', 'archived'].includes((t.status || '').toLowerCase()));
} else if (kanban && Array.isArray(kanban.tasks)) {
  activeCards = kanban.tasks.filter(t => !['done', 'archived'].includes((t.status || '').toLowerCase()));
}

// ─── JSON mode ───────────────────────────────────────────────────────────────
if (JSON_OUT) {
  console.log(JSON.stringify({
    schema: 1,
    active_execution_wave: activeWave,
    wave_ledger: ledger,
    baskets: BASKETS.map(b => ({ ...b, waves: (wavesByBasket[b.n] || []).map(w => w.label) })),
    ship: { shipped_unverified: shippedUnverified, cap: shipCap, throttled: shipThrottled },
    parked_on_abhi: parkedOnAbhi,
    kanban_active_count: activeCards.length,
    asc_newest_build: asc,
    roster,
  }, null, 2));
  process.exit(sawError ? 2 : 0);
}

// ─── pretty print ────────────────────────────────────────────────────────────
const line = () => console.log(dim('─'.repeat(72)));
console.log('');
console.log(bold(cyan('  WAVE PIPELINE — conveyor status')) + dim('   (read-only)'));
console.log(dim('  ' + new Date().toISOString()));
line();

// The belt
console.log(bold('  BASKETS'));
for (const b of BASKETS) {
  const waves = (wavesByBasket[b.n] || []);
  const tag = waves.length
    ? green(waves.map(w => `${w.label} [${w.stage}]`).join(', '))
    : dim('empty');
  let extra = '';
  if (b.n === 3 && shipThrottled) extra = '  ' + red('⚠ THROTTLED (WIP cap hit)');
  if (b.n === 2 && activeCards.length) extra = '  ' + yellow(`${activeCards.length} active Kanban card(s)`);
  console.log(`   ${bold('[' + b.n + ' ' + b.name.padEnd(8) + ']')} ${dim(b.note)}`);
  console.log(`        └─ ${tag}${extra}`);
}
line();

// Pointer + backpressure
console.log(bold('  POINTER'));
console.log(`   active_execution_wave: ${cyan(activeWave)}   ${dim('(advances on SHIP, not VERIFY)')}`);
const capColor = shipThrottled ? red : green;
console.log(`   ship buffer: ${capColor(`${shippedUnverified}/${shipCap}`)} shipped-unverified` +
  (shipThrottled ? red('  → SHIP throttled until Abhi drains a verify') : green('  → ship open')));
line();

// Parking lot
console.log(bold('  PARKED ON ABHI') + dim('  (async — never blocks the belt)'));
if (parkedOnAbhi.length === 0) {
  console.log('   ' + dim('nothing waiting on you'));
} else {
  for (const p of parkedOnAbhi) {
    console.log(`   • ${yellow(p.wave)} (build ${p.build_no}) — ${p.waiting_for}`);
  }
}
line();

// ASC truth
if (asc) {
  const st = asc.valid ? green(asc.state) : yellow(asc.state);
  console.log(bold('  TESTFLIGHT') + `   newest build: ${cyan(String(asc.version))} ${st}` +
    dim(`  (uploaded ${asc.uploaded || '?'})`));
  line();
}

// Roster (who's on the belt)
console.log(bold('  ROSTER') + dim('  (profile → model)'));
const order = ['scout', 'architect', 'engineer', 'verifier', 'reviewer', 'orchestrator'];
for (const p of order) {
  if (roster[p]) console.log(`   ${p.padEnd(13)} ${dim(roster[p])}`);
}
line();
console.log(dim('  contract: docs/autonomous/wave-pipeline.md   |   this tool never mutates state'));
console.log('');

process.exit(sawError ? 2 : 0);
