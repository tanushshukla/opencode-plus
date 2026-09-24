// Run against the actual patched preview source, not a reimplementation.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const source = process.env.OPENCHAMBER_TEST_SOURCE || '/opt/openchamber-preview';
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ha-usage-'));
const previous = Object.fromEntries(['HOME', 'USERPROFILE', 'OPENCODE_DB'].map((key) => [key, process.env[key]]));
const originalFetch = globalThis.fetch;
const dbPath = path.join(directory, 'v2.db');
process.env.HOME = directory;
process.env.USERPROFILE = directory;
process.env.OPENCODE_DB = dbPath;
const legacy = path.join(directory, '.local/share/opencode');
fs.mkdirSync(legacy, { recursive: true });
fs.writeFileSync(path.join(legacy, 'auth.json'), JSON.stringify({
  openai: { type: 'oauth', access: 'fixture-stale-v1', refresh: 'fixture-legacy-refresh', expires: 1 },
}));
const db = new DatabaseSync(dbPath);
db.exec(`CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT, value TEXT,
  active INTEGER, time_created INTEGER, time_updated INTEGER)`);
const insert = db.prepare('INSERT INTO credential VALUES (?, ?, ?, ?, ?, ?)');
const oauth = (access) => JSON.stringify({ type: 'oauth', access, refresh: 'fixture-refresh', expires: 9999999999999, metadata: { accountID: 'fixture-account' } });
const auth = await import(pathToFileURL(path.join(source, 'packages/web/server/lib/opencode/auth.js')));
const quota = await import(pathToFileURL(path.join(source, 'packages/web/server/lib/quota/providers/codex.js')));

test('managed Usage follows V2 login, refresh, account selection and disconnect without legacy fallback', async (t) => {
  t.after(() => {
    globalThis.fetch = originalFetch;
    db.close();
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    fs.rmSync(directory, { recursive: true, force: true });
  });
  insert.run('older', 'openai', oauth('fixture-inactive'), 0, 1, 999);
  insert.run('selected', 'openai', oauth('fixture-current'), 1, 2, 2);
  let expected = 'fixture-current';
  let calls = 0;
  globalThis.fetch = async (url, options) => {
    calls++;
    assert.equal(url, 'https://chatgpt.com/backend-api/wham/usage');
    assert.equal(options.headers.Authorization, `Bearer ${expected}`);
    assert.equal(options.headers['ChatGPT-Account-Id'], 'fixture-account');
    return new Response(JSON.stringify({ rate_limit: { primary_window: { used_percent: 25, limit_window_seconds: 18000, reset_at: 123456 } } }));
  };
  const before = fs.readFileSync(dbPath);
  assert.equal((await quota.fetchQuota()).ok, true);
  assert.equal(calls, 1);
  assert.deepEqual(fs.readFileSync(dbPath), before, 'Quota must not write the provider database');
  expected = 'fixture-refreshed';
  db.prepare('UPDATE credential SET value=? WHERE id=?').run(oauth(expected), 'selected');
  assert.equal((await quota.fetchQuota()).ok, true, 'Read refreshed credentials on each request');
  db.exec('UPDATE credential SET active=0');
  assert.equal(auth.readAuthFile().openai.access, expected, 'Fallback matches backend creation order, not last refresh time');
  db.prepare('UPDATE credential SET value=?, active=1 WHERE id=?').run(JSON.stringify({ type: 'future' }), 'selected');
  assert.equal(auth.readAuthFile().openai, undefined, 'Unsupported active account must not select another account');
  db.exec('DELETE FROM credential');
  assert.equal(quota.isConfigured(), false, 'Disconnect must not resurrect V1 sign-in');
  assert.equal((await quota.fetchQuota()).configured, false);
  assert.equal(calls, 2);
  process.env.OPENCODE_DB = path.join(directory, 'missing.db');
  assert.throws(() => auth.readAuthFile(), /Managed provider credentials unavailable/);
  assert.equal(fs.existsSync(process.env.OPENCODE_DB), false, 'Reader must not create databases');
  delete process.env.OPENCODE_DB;
  assert.throws(() => auth.readAuthFile(), /Managed provider credentials unavailable/);
  process.env.OPENCODE_DB = dbPath;
  insert.run('selected', 'openai', oauth(expected), 1, 2, 2);
  globalThis.fetch = async () => new Response('', { status: 401 });
  const denied = await quota.fetchQuota();
  assert.equal(denied.ok, false);
  assert.match(denied.error, /usage authorization expired/);
  assert.doesNotMatch(JSON.stringify(denied), /fixture-refreshed|fixture-refresh|fixture-stale-v1/);
});
