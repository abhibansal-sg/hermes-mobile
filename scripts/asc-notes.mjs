#!/usr/bin/env node
/**
 * asc-notes.mjs — push "What to Test" release notes to the newest TestFlight build.
 *
 * Usage:
 *   node scripts/asc-notes.mjs --build 55 --notes-file /tmp/notes-55.txt
 *   node scripts/asc-notes.mjs --build 55 --notes "one-line notes"
 *
 * Auth: same env/defaults as asc-poll.mjs (ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID/ASC_APP_ID).
 * Flow: find build by version -> GET its betaBuildLocalizations (en-US) -> PATCH whatsNew
 *       (create the localization if missing).
 * Exit: 0 = notes set, 1 = build not found, 2 = auth/API error.
 */
import { readFileSync } from 'node:fs';
import { createSign } from 'node:crypto';
import { homedir } from 'node:os';
import { existsSync } from 'node:fs';

const argv = process.argv.slice(2);
const arg = (n) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : null; };
const BUILD = arg('--build');
const NOTES = arg('--notes') ?? (arg('--notes-file') ? readFileSync(arg('--notes-file'), 'utf8') : null);
if (!BUILD || !NOTES) { console.error('usage: asc-notes.mjs --build N (--notes "..." | --notes-file F)'); process.exit(2); }

const KEY_ID = process.env.ASC_KEY_ID || '3DHXXG4GHQ';
const ISSUER = process.env.ASC_ISSUER_ID || 'd7deff8e-5489-4d18-995d-c8a10f854118';
const APP_ID = process.env.ASC_APP_ID || '6777140135';
const keyPath = process.env.ASC_KEY_PATH
  || [`${homedir()}/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8`,
      `${homedir()}/.appstoreconnect/private/AuthKey_${KEY_ID}.p8`].find(existsSync);
if (!keyPath) { console.error('[asc-notes] no .p8 key found'); process.exit(2); }
const KEY = readFileSync(keyPath, 'utf8');

function jwt() {
  const now = Math.floor(Date.now() / 1000);
  const h = Buffer.from(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })).toString('base64url');
  const p = Buffer.from(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' })).toString('base64url');
  const s = createSign('SHA256').update(`${h}.${p}`).sign({ key: KEY, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `${h}.${p}.${s}`;
}
const API = 'https://api.appstoreconnect.apple.com/v1';
async function asc(method, path, body) {
  const r = await fetch(`${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${jwt()}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  if (!r.ok) { console.error(`[asc-notes] ${method} ${path} -> ${r.status}: ${text.slice(0, 300)}`); process.exit(2); }
  return text ? JSON.parse(text) : {};
}

// 1. find the build by version
const builds = await asc('GET', `/builds?filter[app]=${APP_ID}&filter[version]=${BUILD}&limit=1`);
const build = builds.data?.[0];
if (!build) { console.error(`[asc-notes] build ${BUILD} not found on ASC`); process.exit(1); }

// 2. existing en-US localization?
const locs = await asc('GET', `/builds/${build.id}/betaBuildLocalizations`);
const enUS = locs.data?.find((l) => l.attributes.locale === 'en-US');

if (enUS) {
  await asc('PATCH', `/betaBuildLocalizations/${enUS.id}`, {
    data: { id: enUS.id, type: 'betaBuildLocalizations', attributes: { whatsNew: NOTES.slice(0, 4000) } },
  });
} else {
  await asc('POST', `/betaBuildLocalizations`, {
    data: {
      type: 'betaBuildLocalizations',
      attributes: { locale: 'en-US', whatsNew: NOTES.slice(0, 4000) },
      relationships: { build: { data: { id: build.id, type: 'builds' } } },
    },
  });
}
console.log(`[asc-notes] What-to-Test set on build ${BUILD} (${NOTES.length} chars)`);
