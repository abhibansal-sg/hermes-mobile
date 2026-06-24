#!/usr/bin/env node
/**
 * asc-poll.mjs — READ-ONLY App Store Connect build-status watcher.
 *
 * Polls ASC for the most-recent (or a specific) TestFlight build until it leaves
 * PROCESSING — i.e. reaches VALID or INVALID — then prints a one-line verdict and
 * exits. This is the "safe first loop" of the autonomy ladder: it only READS ASC
 * (GET /v1/builds), never mutates anything, never ships. It replaces the hand-rolled
 * /tmp JWT-poll snippet re-created on every ship.
 *
 *   node scripts/asc-poll.mjs                 # watch the newest build until VALID/INVALID
 *   node scripts/asc-poll.mjs --version 52    # watch a specific CFBundleVersion
 *   node scripts/asc-poll.mjs --once          # print current status once, don't loop
 *   node scripts/asc-poll.mjs --json          # machine-readable final line
 *
 * Exit codes (so the governor loop can branch without parsing prose):
 *   0  = build VALID (processing succeeded)
 *   3  = build INVALID / failed processing
 *   4  = timed out still PROCESSING (no verdict within the ceiling)
 *   2  = usage / auth / API error
 *
 * Env (same contract as apps/ios/ci_scripts/asc-cloud.mjs — shared credential scoping):
 *   ASC_KEY_PATH   path to .p8   (default: ~/.appstoreconnect/private_keys/AuthKey_<kid>.p8
 *                                          then ~/.appstoreconnect/private/AuthKey_<kid>.p8)
 *   ASC_KEY_ID     key id        (default 3DHXXG4GHQ)
 *   ASC_ISSUER_ID  issuer uuid   (default d7deff8e-5489-4d18-995d-c8a10f854118)
 *   ASC_APP_ID     numeric appId (default 6777140135)
 *   ASC_POLL_INTERVAL_S  seconds between polls (default 60)
 *   ASC_POLL_MAX_MIN     minutes ceiling       (default 30)
 *
 * NEVER commit the .p8 — only the non-secret kid/issuer/appId defaults live here,
 * matching the API-key-scoping discipline.
 */

import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const DEFAULT_KEY_ID    = '3DHXXG4GHQ';
const DEFAULT_ISSUER_ID = 'd7deff8e-5489-4d18-995d-c8a10f854118';
const DEFAULT_APP_ID    = '6777140135';
const ASC_BASE          = 'https://api.appstoreconnect.apple.com/v1';

const POLL_INTERVAL_MS  = (Number(process.env.ASC_POLL_INTERVAL_S) || 60) * 1000;
const MAX_WAIT_MS       = (Number(process.env.ASC_POLL_MAX_MIN)   || 30) * 60 * 1000;
const RETRY_ATTEMPTS    = 3;
const RETRY_DELAY_MS    = 5_000;

// ─── args ────────────────────────────────────────────────────────────────────
const argv      = process.argv.slice(2);
const wantVer   = (() => { const i = argv.indexOf('--version'); return i >= 0 ? argv[i + 1] : null; })();
const once      = argv.includes('--once');
const asJson    = argv.includes('--json');

// ─── key resolution + ES256 JWT (reused verbatim from asc-cloud.mjs) ──────────
function resolveKeyPath() {
  if (process.env.ASC_KEY_PATH) return process.env.ASC_KEY_PATH;
  const kid = process.env.ASC_KEY_ID ?? DEFAULT_KEY_ID;
  const candidates = [
    path.join(os.homedir(), '.appstoreconnect', 'private_keys', `AuthKey_${kid}.p8`),
    path.join(os.homedir(), '.appstoreconnect', 'private',      `AuthKey_${kid}.p8`),
  ];
  for (const p of candidates) if (fs.existsSync(p)) return p;
  throw new Error(`Cannot find .p8 key. Tried:\n${candidates.join('\n')}\nSet ASC_KEY_PATH to override.`);
}
function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}
function mintJWT() {
  const kid      = process.env.ASC_KEY_ID    ?? DEFAULT_KEY_ID;
  const issuerId = process.env.ASC_ISSUER_ID ?? DEFAULT_ISSUER_ID;
  const keyPem   = fs.readFileSync(resolveKeyPath(), 'utf8');
  const iat = Math.floor(Date.now() / 1000);
  const header  = b64url(JSON.stringify({ alg: 'ES256', kid, typ: 'JWT' }));
  const payload = b64url(JSON.stringify({ iss: issuerId, iat, exp: iat + 1100, aud: 'appstoreconnect-v1' }));
  const data = Buffer.from(`${header}.${payload}`);
  const sig  = crypto.sign('SHA256', data, { key: keyPem, dsaEncoding: 'ieee-p1363' });
  return `${header}.${payload}.${b64url(sig)}`;
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function ascGet(urlOrPath, attempt = 1) {
  const url = urlOrPath.startsWith('http') ? urlOrPath : `${ASC_BASE}${urlOrPath}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${mintJWT()}` } }); // re-mint per call (long polls)
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    if ((res.status >= 500 || res.status === 429) && attempt < RETRY_ATTEMPTS) {
      console.error(`[asc-poll] HTTP ${res.status} (attempt ${attempt}/${RETRY_ATTEMPTS}) — retry in ${RETRY_DELAY_MS / 1000}s`);
      await sleep(RETRY_DELAY_MS * attempt);
      return ascGet(urlOrPath, attempt + 1);
    }
    throw new Error(`ASC GET ${url} → ${res.status}\n${text}`);
  }
  return res.json();
}

// ─── fetch the build we care about ────────────────────────────────────────────
async function fetchBuild() {
  const appId = process.env.ASC_APP_ID ?? DEFAULT_APP_ID;
  // Newest builds first; filter by version client-side when --version given.
  const data = await ascGet(
    `/builds?filter[app]=${appId}&sort=-uploadedDate&limit=20` +
    `&fields[builds]=version,processingState,uploadedDate,expired`
  );
  const builds = data?.data ?? [];
  if (!builds.length) return null;
  if (wantVer) return builds.find(b => b.attributes?.version === String(wantVer)) ?? null;
  return builds[0];
}

function describe(b) {
  return {
    version: b?.attributes?.version ?? '?',
    state:   b?.attributes?.processingState ?? 'UNKNOWN', // PROCESSING | VALID | INVALID | FAILED
    uploaded: b?.attributes?.uploadedDate ?? '?',
  };
}

async function main() {
  const target = wantVer ? `build ${wantVer}` : 'newest build';
  const start = Date.now();
  let last = null;
  while (true) {
    let b;
    try { b = await fetchBuild(); }
    catch (e) { console.error(`[asc-poll] ${e.message}`); process.exit(2); }

    if (!b) {
      // build not visible yet (ASC ingest lag) — keep waiting unless --once
      console.error(`[asc-poll] ${target} not visible on ASC yet…`);
    } else {
      const d = describe(b);
      if (d.state !== last) {
        console.error(`[asc-poll] ${target}: version=${d.version} state=${d.state} (uploaded ${d.uploaded})`);
        last = d.state;
      }
      const valid   = d.state === 'VALID';
      const invalid = d.state === 'INVALID' || d.state === 'FAILED';
      if (valid || invalid || once) {
        const verdict = { version: d.version, state: d.state, valid, uploaded: d.uploaded };
        if (asJson) console.log(JSON.stringify(verdict));
        else console.log(`RESULT build ${d.version}: ${d.state}`);
        process.exit(valid ? 0 : (once && d.state === 'PROCESSING' ? 4 : (invalid ? 3 : 0)));
      }
    }
    if (Date.now() - start >= MAX_WAIT_MS) {
      console.error(`[asc-poll] TIMEOUT — still not VALID after ${MAX_WAIT_MS / 60000} min`);
      if (asJson) console.log(JSON.stringify({ version: wantVer ?? '?', state: last ?? 'PROCESSING', valid: false, timedOut: true }));
      process.exit(4);
    }
    await sleep(POLL_INTERVAL_MS);
  }
}

main();
