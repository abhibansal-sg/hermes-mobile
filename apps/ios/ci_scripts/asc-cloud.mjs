#!/usr/bin/env node
/**
 * asc-cloud.mjs — Xcode Cloud driver via App Store Connect API
 *
 * Subcommands:
 *   list-workflows              List all ciWorkflows for the app (id + name)
 *   trigger <workflowId> <ref>  Start a cloud build on a branch ref
 *   status  <buildRunId>        Print current status + action summaries
 *   wait    <buildRunId>        Poll until complete; exit 0=SUCCEEDED non-zero otherwise
 *   issues  <buildRunId>        Print test failures + warning counts per action
 *
 * Configuration (env overrides hardcoded defaults):
 *   ASC_KEY_PATH   path to .p8 file  (default: ~/.appstoreconnect/private_keys/AuthKey_3DHXXG4GHQ.p8
 *                                              then ~/.appstoreconnect/private/AuthKey_3DHXXG4GHQ.p8)
 *   ASC_KEY_ID     key ID            (default: 3DHXXG4GHQ)
 *   ASC_ISSUER_ID  issuer UUID       (default: d7deff8e-5489-4d18-995d-c8a10f854118)
 *   ASC_APP_ID     numeric App ID    (default: 6777140135)
 */

import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// ─── Constants / defaults ────────────────────────────────────────────────────

const DEFAULT_KEY_ID    = '3DHXXG4GHQ';
const DEFAULT_ISSUER_ID = 'd7deff8e-5489-4d18-995d-c8a10f854118';
const DEFAULT_APP_ID    = '6777140135';
const ASC_BASE          = 'https://api.appstoreconnect.apple.com/v1';

const POLL_INTERVAL_MS  = 60_000;   // 60 s between polls in `wait`
const MAX_WAIT_MS       = 45 * 60 * 1000; // 45-minute ceiling
const RETRY_ATTEMPTS    = 3;        // transient HTTP error retries
const RETRY_DELAY_MS    = 5_000;    // delay between retries

// ─── Key resolution ──────────────────────────────────────────────────────────

function resolveKeyPath() {
  if (process.env.ASC_KEY_PATH) return process.env.ASC_KEY_PATH;
  const kid = process.env.ASC_KEY_ID ?? DEFAULT_KEY_ID;
  const candidates = [
    path.join(os.homedir(), '.appstoreconnect', 'private_keys', `AuthKey_${kid}.p8`),
    path.join(os.homedir(), '.appstoreconnect', 'private',      `AuthKey_${kid}.p8`),
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) return p;
  }
  throw new Error(
    `Cannot find .p8 key. Tried:\n${candidates.join('\n')}\n` +
    `Set ASC_KEY_PATH to override.`
  );
}

// ─── JWT minting (ES256) ─────────────────────────────────────────────────────
// Header: {alg:ES256, kid, typ:JWT}
// Payload: {iss, iat, exp:iat+1100, aud:'appstoreconnect-v1'}
// Signature: DER → IEEE P1363 (r‖s, 64 bytes) as required by ASC

function b64url(buf) {
  return Buffer.from(buf)
    .toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

function mintJWT() {
  const kid      = process.env.ASC_KEY_ID    ?? DEFAULT_KEY_ID;
  const issuerId = process.env.ASC_ISSUER_ID ?? DEFAULT_ISSUER_ID;
  const keyPath  = resolveKeyPath();
  const keyPem   = fs.readFileSync(keyPath, 'utf8');

  const iat = Math.floor(Date.now() / 1000);
  const exp = iat + 1100; // slightly under 20-min max; safe for single calls

  const header  = b64url(JSON.stringify({ alg: 'ES256', kid, typ: 'JWT' }));
  const payload = b64url(JSON.stringify({
    iss: issuerId,
    iat,
    exp,
    aud: 'appstoreconnect-v1',
  }));

  const data = Buffer.from(`${header}.${payload}`);
  const sig  = crypto.sign('SHA256', data, { key: keyPem, dsaEncoding: 'ieee-p1363' });

  return `${header}.${payload}.${b64url(sig)}`;
}

// ─── HTTP helpers ────────────────────────────────────────────────────────────

async function ascFetch(method, urlOrPath, body, attempt = 1) {
  const url    = urlOrPath.startsWith('http') ? urlOrPath : `${ASC_BASE}${urlOrPath}`;
  const jwt    = mintJWT(); // re-mint on every request — safe for long polls
  const opts   = {
    method,
    headers: {
      'Authorization': `Bearer ${jwt}`,
      'Content-Type':  'application/json',
    },
  };
  if (body != null) opts.body = JSON.stringify(body);

  const res = await fetch(url, opts);

  if (!res.ok) {
    const text = await res.text().catch(() => '');
    // Retry on 5xx / 429
    if ((res.status >= 500 || res.status === 429) && attempt < RETRY_ATTEMPTS) {
      console.error(`[asc] HTTP ${res.status} on attempt ${attempt}/${RETRY_ATTEMPTS} — retrying in ${RETRY_DELAY_MS / 1000}s…`);
      await sleep(RETRY_DELAY_MS * attempt); // back-off
      return ascFetch(method, urlOrPath, body, attempt + 1);
    }
    throw new Error(`ASC API ${method} ${url} → ${res.status}\n${text}`);
  }

  if (res.status === 204) return null;
  return res.json();
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// Paginate through all pages of a LIST response
async function ascFetchAll(path) {
  const items = [];
  let url = path;
  while (url) {
    const data = await ascFetch('GET', url);
    if (Array.isArray(data?.data)) items.push(...data.data);
    url = data?.links?.next ?? null;
  }
  return items;
}

// ─── Subcommand implementations ──────────────────────────────────────────────

async function getProductId(appId) {
  // /apps/{appId}/ciProduct returns the single ciProduct for that app
  const data = await ascFetch('GET', `/apps/${appId}/ciProduct`);
  const id = data?.data?.id;
  if (!id) throw new Error(`No ciProduct found for app ${appId}`);
  return id;
}

async function cmdListWorkflows() {
  const appId = process.env.ASC_APP_ID ?? DEFAULT_APP_ID;
  console.log(`Fetching workflows for app ${appId}…\n`);

  // ASC v1: workflows live under the app's ciProduct
  const productId = await getProductId(appId);
  const workflows = await ascFetchAll(`/ciProducts/${productId}/workflows`);

  if (!workflows.length) {
    console.log('No workflows found.');
    return;
  }

  console.log(`${'ID'.padEnd(26)}  NAME`);
  console.log('-'.repeat(60));
  for (const wf of workflows) {
    const name = wf.attributes?.name ?? '(unnamed)';
    console.log(`${wf.id.padEnd(26)}  ${name}`);
  }
  console.log(`\n${workflows.length} workflow(s) total.`);
}

async function cmdTrigger(workflowId, gitRef) {
  if (!workflowId || !gitRef) {
    die('Usage: asc-cloud.mjs trigger <workflowId> <gitRef>\n  e.g. trigger abc123 refs/heads/phase2-upstream-rebase');
  }

  // Normalize: strip refs/heads/ prefix to get a plain branch name
  const branchName = gitRef.startsWith('refs/heads/')
    ? gitRef.slice('refs/heads/'.length)
    : gitRef;

  console.log(`Triggering workflow ${workflowId} on branch "${branchName}"…`);

  // Step 1: Resolve the workflow's repository
  console.log(`  Resolving repository for workflow ${workflowId}…`);
  const wfData = await ascFetch('GET', `/ciWorkflows/${workflowId}?include=repository`);
  const repoRel = wfData?.data?.relationships?.repository?.data;
  if (!repoRel?.id) {
    throw new Error(`Could not resolve repository for workflow ${workflowId}. Response: ${JSON.stringify(wfData)}`);
  }
  const repoId = repoRel.id;
  console.log(`  Repository id: ${repoId}`);

  // Step 2: List git references for the repository and find the matching branch
  console.log(`  Fetching git references for repository ${repoId}…`);
  const allRefs = await ascFetchAll(`/scmRepositories/${repoId}/gitReferences?limit=200`);
  const matchedRef = allRefs.find(
    r => r.attributes?.kind === 'BRANCH' && r.attributes?.name === branchName
  );

  if (!matchedRef) {
    const availableBranches = allRefs
      .filter(r => r.attributes?.kind === 'BRANCH')
      .map(r => r.attributes?.name)
      .filter(Boolean)
      .slice(0, 10);
    throw new Error(
      `Branch "${branchName}" not found in scmGitReferences for repository ${repoId}.\n` +
      `Available branches (first 10): ${availableBranches.join(', ')}\n` +
      `Total refs fetched: ${allRefs.length}`
    );
  }

  const gitReferenceId = matchedRef.id;
  console.log(`  Resolved branch "${branchName}" → scmGitReferences id: ${gitReferenceId}`);

  // Step 3: POST /v1/ciBuildRuns with sourceBranchOrTag relationship (no sourceCommitSha)
  const body = {
    data: {
      type: 'ciBuildRuns',
      relationships: {
        workflow: { data: { type: 'ciWorkflows', id: workflowId } },
        sourceBranchOrTag: { data: { type: 'scmGitReferences', id: gitReferenceId } },
      },
    },
  };

  const res = await ascFetch('POST', '/ciBuildRuns', body);
  const run = res?.data;
  if (!run) throw new Error('Unexpected empty response from ciBuildRuns POST');

  const buildNumber = run.attributes?.number ?? '—';
  console.log(`\nBuild run created:`);
  console.log(`  ID:          ${run.id}`);
  console.log(`  Build #:     ${buildNumber}`);
  console.log(`  Status:      ${run.attributes?.executionProgress ?? 'PENDING'}`);
  console.log(`\nUse: node asc-cloud.mjs wait ${run.id}`);
}

async function cmdStatus(buildRunId) {
  if (!buildRunId) die('Usage: asc-cloud.mjs status <buildRunId>');

  const [runData, actionsData] = await Promise.all([
    ascFetch('GET', `/ciBuildRuns/${buildRunId}`),
    ascFetchAll(`/ciBuildRuns/${buildRunId}/actions`),
  ]);

  const run   = runData?.data;
  const attrs = run?.attributes ?? {};

  console.log(`Build Run: ${buildRunId}`);
  console.log(`  Progress:   ${attrs.executionProgress ?? 'UNKNOWN'}`);
  console.log(`  Completion: ${attrs.completionStatus  ?? 'IN_PROGRESS'}`);
  console.log(`  Started:    ${attrs.startedDate       ?? '—'}`);
  console.log(`  Finished:   ${attrs.finishedDate      ?? '—'}`);

  if (actionsData.length) {
    console.log(`\nActions (${actionsData.length}):`);
    for (const action of actionsData) {
      const a = action.attributes ?? {};
      const issues = a.issueCounts ?? {};
      console.log(
        `  [${(a.name ?? action.id).padEnd(24)}]` +
        `  ${(a.executionProgress ?? '').padEnd(12)}` +
        `  ${(a.completionStatus  ?? 'IN_PROGRESS').padEnd(10)}` +
        `  errors:${issues.errors ?? 0} warnings:${issues.warnings ?? 0} tests:${issues.testFailures ?? 0}`
      );
    }
  }
}

async function cmdWait(buildRunId) {
  if (!buildRunId) die('Usage: asc-cloud.mjs wait <buildRunId>');

  const deadline = Date.now() + MAX_WAIT_MS;
  console.log(`Polling build run ${buildRunId} (cap: 45 min)…`);

  while (true) {
    if (Date.now() > deadline) {
      console.error(`\nTimeout after ${MAX_WAIT_MS / 60_000} minutes. Build may still be running.`);
      process.exit(2);
    }

    let runData;
    try {
      runData = await ascFetch('GET', `/ciBuildRuns/${buildRunId}`);
    } catch (err) {
      console.error(`[asc] Poll error (continuing): ${err.message}`);
      await sleep(POLL_INTERVAL_MS);
      continue;
    }

    const attrs    = runData?.data?.attributes ?? {};
    const progress = attrs.executionProgress ?? '';
    const status   = attrs.completionStatus  ?? '';

    process.stdout.write(`[${new Date().toISOString()}] ${progress} / ${status || 'in-progress'}\n`);

    if (progress === 'COMPLETE') {
      console.log(`\nFinal status: ${status}`);
      if (status === 'SUCCEEDED') {
        process.exit(0);
      } else {
        console.error(`Build did not succeed (${status}). Run 'issues ${buildRunId}' for details.`);
        process.exit(1);
      }
    }

    await sleep(POLL_INTERVAL_MS);
  }
}

async function cmdIssues(buildRunId) {
  if (!buildRunId) die('Usage: asc-cloud.mjs issues <buildRunId>');

  const actionsData = await ascFetchAll(`/ciBuildRuns/${buildRunId}/actions`);

  if (!actionsData.length) {
    console.log('No actions found for this build run.');
    return;
  }

  let totalFailures = 0;
  let totalWarnings = 0;

  for (const action of actionsData) {
    const actionName = action.attributes?.name ?? action.id;
    const counts     = action.attributes?.issueCounts ?? {};

    console.log(`\n── Action: ${actionName} ─────────────────────`);
    console.log(`   errors:${counts.errors ?? 0}  warnings:${counts.warnings ?? 0}  testFailures:${counts.testFailures ?? 0}`);

    // Fetch per-action issues
    let issues;
    try {
      issues = await ascFetchAll(`/ciActions/${action.id}/issues`);
    } catch (err) {
      console.error(`   [asc] Could not fetch issues for action ${action.id}: ${err.message}`);
      continue;
    }

    const failures = issues.filter(i => i.attributes?.issueType === 'TEST_FAILURE');
    const warnings = issues.filter(i => i.attributes?.issueType === 'WARNING');

    if (failures.length) {
      console.log(`\n   TEST FAILURES (${failures.length}):`);
      for (const f of failures) {
        const a = f.attributes ?? {};
        console.log(`     • ${a.message ?? '(no message)'}`);
        if (a.fileReference) console.log(`       at ${a.fileReference}`);
      }
    } else {
      console.log('   No test failures.');
    }

    console.log(`   Warnings: ${warnings.length}`);
    totalFailures += failures.length;
    totalWarnings += warnings.length;
  }

  console.log(`\n${'─'.repeat(50)}`);
  console.log(`Total test failures: ${totalFailures}`);
  console.log(`Total warnings:      ${totalWarnings}`);
}

// ─── Entry point ─────────────────────────────────────────────────────────────

function die(msg) {
  console.error(`Error: ${msg}`);
  process.exit(1);
}

const USAGE = `
Xcode Cloud driver — App Store Connect API

Usage:
  node asc-cloud.mjs list-workflows
  node asc-cloud.mjs trigger <workflowId> <gitRef>
  node asc-cloud.mjs status  <buildRunId>
  node asc-cloud.mjs wait    <buildRunId>
  node asc-cloud.mjs issues  <buildRunId>

Env vars:
  ASC_KEY_PATH   path to .p8 file (default: ~/.appstoreconnect/private_keys/AuthKey_<KID>.p8)
  ASC_KEY_ID     key ID           (default: 3DHXXG4GHQ)
  ASC_ISSUER_ID  issuer UUID      (default: d7deff8e-5489-4d18-995d-c8a10f854118)
  ASC_APP_ID     numeric App ID   (default: 6777140135)
`.trim();

const [,, cmd, ...args] = process.argv;

switch (cmd) {
  case 'list-workflows': await cmdListWorkflows(); break;
  case 'trigger':        await cmdTrigger(args[0], args[1]); break;
  case 'status':         await cmdStatus(args[0]); break;
  case 'wait':           await cmdWait(args[0]); break;
  case 'issues':         await cmdIssues(args[0]); break;
  default:
    console.log(USAGE);
    if (cmd) console.error(`\nUnknown subcommand: ${cmd}`);
    process.exit(cmd ? 1 : 0);
}
