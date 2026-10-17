import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = fileURLToPath(new URL('../..', import.meta.url));
const production = {
  TUIST_TOASTTY_PUSH_RELAY_URL: 'https://push.example.com',
  TUIST_TOASTTY_PUSH_RELAY_ID: 'toastty-push-prod-v1',
  TUIST_TOASTTY_PUSH_APNS_ENVIRONMENT: 'production',
};
const development = {
  TUIST_TOASTTY_PUSH_RELAY_URL: 'https://push-dev.example.com',
  TUIST_TOASTTY_PUSH_RELAY_ID: 'toastty-push-dev-v1',
  TUIST_TOASTTY_PUSH_APNS_ENVIRONMENT: 'development',
};

function evaluate(overrides = {}) {
  const environment = { ...process.env };
  for (const key of Object.keys(environment)) {
    if (key.startsWith('TUIST_TOASTTY_PUSH_') || key.startsWith('TOASTTY_PUSH_')
        || key === 'TUIST_TOASTTY_DISABLE_PUSH' || key === 'TUIST_DISTRIBUTION_SIGNING') {
      delete environment[key];
    }
  }
  const result = spawnSync('tuist', ['dump', '--path', root], {
    cwd: root,
    env: { ...environment, TUIST_DISABLE_GHOSTTY: '1', ...overrides },
    encoding: 'utf8',
    timeout: 120_000,
    maxBuffer: 8 * 1024 * 1024,
  });
  assert.ifError(result.error);
  assert.equal(result.signal, null, 'Tuist must finish rather than time out or crash');
  return result;
}

function reject(overrides, diagnostic) {
  const result = evaluate(overrides);
  assert.notEqual(result.status, 0, 'Tuist must reject this configuration');
  assert.match(result.stdout + result.stderr, diagnostic);
}

function embeddedSettings(overrides) {
  const result = evaluate(overrides);
  assert.equal(result.status, 0, result.stderr);
  const manifest = JSON.parse(result.stdout);
  const app = manifest.targets.find(target => target.name === 'ToasttyApp');
  const info = app.infoPlist.extendingDefault.with;
  return ['ToasttyPushRelayURL', 'ToasttyPushRelayID', 'ToasttyPushAPNsEnvironment']
    .map(key => info[key].string._0);
}

test('missing push configuration fails instead of silently disabling alerts', () => {
  reject({}, /Configure the Mac push relay with TUIST_TOASTTY_PUSH_RELAY_URL/);
});

test('relay metadata without a URL fails; URL-only development keeps its defaults', () => {
  const { TUIST_TOASTTY_PUSH_RELAY_URL: url, ...metadata } = development;
  reject(metadata, /Configure the Mac push relay with TUIST_TOASTTY_PUSH_RELAY_URL/);
  assert.deepEqual(embeddedSettings({ TUIST_TOASTTY_PUSH_RELAY_URL: url }), Object.values(development));
});

test('production and development settings reach the app manifest', () => {
  for (const settings of [production, development]) {
    assert.deepEqual(embeddedSettings(settings), Object.values(settings));
  }
});

test('explicit no-push builds clear relay settings even with ambient configuration', () => {
  for (const settings of [{}, { ...production, TUIST_TOASTTY_PUSH_RELAY_URL: 'invalid-ignored-origin' }]) {
    assert.deepEqual(embeddedSettings({ ...settings, TUIST_TOASTTY_DISABLE_PUSH: '1' }),
      ['', 'toastty-push-dev-v1', 'development']);
  }
});

test('zero keeps push configuration required and invalid toggles fail', () => {
  reject({ TUIST_TOASTTY_DISABLE_PUSH: '0' }, /Configure the Mac push relay with TUIST_TOASTTY_PUSH_RELAY_URL/);
  reject({ ...production, TUIST_TOASTTY_DISABLE_PUSH: 'true' }, /TUIST_TOASTTY_DISABLE_PUSH must be 0 or 1/);
  assert.deepEqual(embeddedSettings({ ...production, TUIST_TOASTTY_DISABLE_PUSH: '' }), Object.values(production));
});

test('distribution builds cannot opt out of push', () => {
  reject({ ...production, TUIST_TOASTTY_DISABLE_PUSH: '1', TUIST_DISTRIBUTION_SIGNING: '1' },
    /Distribution builds cannot disable push/);
});

test('release command rejects opt-out before requesting credentials or building', () => {
  for (const [flag, diagnostic] of [
    ['1', /Distribution builds cannot disable push/],
    ['true', /TUIST_TOASTTY_DISABLE_PUSH must be 0 or 1/],
  ]) {
    const result = spawnSync('bash', ['scripts/release/release.sh'], {
      cwd: root,
      env: { PATH: process.env.PATH, TUIST_TOASTTY_DISABLE_PUSH: flag },
      encoding: 'utf8', timeout: 5_000,
    });
    assert.ifError(result.error);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, diagnostic);
  }
});

test('invalid configured relay values still fail', () => {
  reject({ ...production, TUIST_TOASTTY_PUSH_RELAY_URL: '' }, /must not be empty/);
  reject({ ...production, TUIST_TOASTTY_PUSH_RELAY_URL: 'http://push.example.com' }, /must be an HTTPS origin/);
  reject({ ...production, TUIST_TOASTTY_PUSH_RELAY_ID: 'invalid relay' }, /may contain only/);
  reject({ ...production, TUIST_TOASTTY_PUSH_APNS_ENVIRONMENT: 'development' }, /must select the same deployment/);
});
