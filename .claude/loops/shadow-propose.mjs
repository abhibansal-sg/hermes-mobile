#!/usr/bin/env node
/**
 * shadow-propose.mjs — the ACT BOUNDARY for a governed stage cycle.
 *
 * A stage-loop does its work (build/verify), then calls THIS to record the outcome.
 * It enforces the governor gates and, while shadow_mode is on, writes a PROPOSAL
 * (what it WOULD do + the evidence) to a local file and acts on NOTHING — no git
 * commit, no Linear transition. The human reads the proposal; only when shadow_mode
 * is flipped off does the same call become a real action (still gated by evidence +
 * the guard hook). This is rung 3 of the trust ladder.
 *
 *   node .claude/loops/shadow-propose.mjs \
 *     --loop verify --issue ABH-201 \
 *     --summary "fix env-var collision" \
 *     --evidence-kind xcresult_or_test_summary --evidence "35 passed, 0 failed" \
 *     --transition "Backlog->In Review (+loop:verified)" \
 *     --diff /tmp/abh201.diff
 *
 * Exit: 0 proposal written (shadow) / would-act allowed (live); non-zero = a governor
 * gate refused (10 disabled, 11 headroom, 30 no-evidence) — the cycle does NOT proceed.
 */
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';
import { execFileSync } from 'node:child_process';

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const GOV = path.join(HERE, 'governor.mjs');
const CFG = JSON.parse(fs.readFileSync(path.join(HERE, 'governor.json'), 'utf8'));
const PROPOSAL_DIR = path.join(HERE, '..', '..', '.hermes-dev', 'loop-proposals');

const a = (n, d = null) => { const i = process.argv.indexOf(n); return i >= 0 ? process.argv[i + 1] : d; };

const loop      = a('--loop', 'verify');
const issue     = a('--issue');
const summary   = a('--summary', '');
const evKind    = a('--evidence-kind', '');
const evidence  = a('--evidence', '');
const transition= a('--transition', '');
const diffPath  = a('--diff', '');
if (!issue) { console.error('shadow-propose: --issue is required'); process.exit(2); }

function gov(args) {
  try { execFileSync('node', [GOV, ...args], { stdio: 'inherit' }); return 0; }
  catch (e) { return e.status ?? 1; }
}

// Concurrency registration. Once we register this loop into the governor's
// active_action_loops, we MUST deregister on the way out (success OR failure OR
// crash) so the cap doesn't leak a stale entry. A single-host single-user loop,
// so a check-then-register race is acceptable; we lean on the governor's own
// register/deregister commands for the atomic write-back.
let registered = false;
function deregister() {
  if (!registered) return;
  registered = false;
  gov(['deregister', '--loop', loop]);
}
process.on('exit', deregister);

// 1) governor preflight (kill-switch / headroom / concurrency) — fail closed.
const pf = gov(['preflight', '--loop', loop, '--action']);
if (pf !== 0) { console.error(`shadow-propose: preflight refused (exit ${pf}) — cycle aborts.`); process.exit(pf); }

// 1b) preflight PASSED → register this action loop so the concurrency cap binds
// for any concurrent loop. Deregistered via the exit handler above.
const rg = gov(['register', '--loop', loop]);
if (rg !== 0) { console.error(`shadow-propose: could not register loop (exit ${rg}) — cycle aborts.`); process.exit(rg); }
registered = true;

// 2) evidence gate — no green without a hard-evidence artifact.
const eg = gov(['evidence', '--kind', evKind, '--artifact', evidence || '']);
if (eg !== 0) { console.error(`shadow-propose: evidence gate refused (exit ${eg}) — will not propose a pass.`); process.exit(eg); }

// 3) shadow vs live.
const shadow = CFG.shadow_mode !== false;
const stamp = new Date().toISOString().replace(/[:.]/g, '-'); // safe filename
fs.mkdirSync(PROPOSAL_DIR, { recursive: true });
const file = path.join(PROPOSAL_DIR, `${issue}-${stamp}.md`);

let diffPreview = '(no diff attached)';
if (diffPath && fs.existsSync(diffPath)) {
  const raw = fs.readFileSync(diffPath, 'utf8');
  diffPreview = raw.length > 8000 ? raw.slice(0, 8000) + '\n…(truncated)…' : raw;
}

const body = `# Loop proposal — ${issue} (${shadow ? 'SHADOW / propose-only' : 'LIVE'})
loop: ${loop}
when: ${stamp}
summary: ${summary}

## Governor gates
- preflight: PASS (enabled, headroom OK, under concurrency cap)
- evidence: PASS — ${evKind} = "${evidence}"

## Proposed action (NOT taken in shadow mode)
- Linear transition: ${transition || '(none specified)'}
- git: would commit the diff below to the work branch (iOS/plugin only; never stock core)

## Diff
\`\`\`diff
${diffPreview}
\`\`\`

---
${shadow
  ? 'SHADOW MODE: nothing was committed or transitioned. Review this proposal; flip shadow_mode=false in governor.json to let the same cycle act.'
  : 'LIVE MODE: the cycle is cleared to act (commit + transition) — still subject to the guard hook on the actual commands.'}
`;

fs.writeFileSync(file, body);
console.error(`\nshadow-propose: ${shadow ? 'PROPOSAL written (no action taken)' : 'CLEARED TO ACT'} → ${file}`);
console.log(file);
process.exit(0);
