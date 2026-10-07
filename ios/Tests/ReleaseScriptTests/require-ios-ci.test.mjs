import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

const root = new URL('../../../', import.meta.url).pathname;
const helper = path.join(root, 'scripts/ci/require-ios-ci.mjs');
const sha = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
const repo = 'figelwump/toastty';
const workflow = 340799440;
const run = { id: 123, run_number: 10, run_attempt: 2, workflow_id: workflow,
  path: '.github/workflows/mobile-ios.yml', head_sha: sha, head_branch: 'main',
  event: 'push', status: 'completed', conclusion: 'success',
  repository: { full_name: repo }, head_repository: { full_name: repo } };
const gate = { name: 'CI gate', run_id: run.id, run_attempt: run.run_attempt, head_sha: sha,
  status: 'completed', conclusion: 'success' };

function invoke({ runs = [run], current = run, final = current, jobs = [gate],
  total = runs.length, jobTotal = jobs.length, errorAt, malformedAt, source = sha,
  repository = repo } = {}) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'toastty-ci-gate-'));
  try {
    const bin = path.join(dir, 'bin');
    mkdirSync(bin);
    const responses = [
      { endpoint: `repos/${repo}/actions/workflows/${workflow}/runs?branch=main&head_sha=${sha}&per_page=100`,
        body: { total_count: total, workflow_runs: runs } },
      { endpoint: `repos/${repo}/actions/runs/${current.id}`, body: current },
      { endpoint: `repos/${repo}/actions/runs/${current.id}/attempts/${current.run_attempt}/jobs?per_page=100`,
        body: { total_count: jobTotal, jobs } },
      { endpoint: `repos/${repo}/actions/runs/${current.id}`, body: final },
    ];
    writeFileSync(path.join(dir, 'fixture.json'), JSON.stringify({ responses, errorAt, malformedAt }));
    writeFileSync(path.join(bin, 'gh'), `#!${process.execPath}\n
import fs from 'node:fs';
const file = process.env.CI_FIXTURE;
const fixture = JSON.parse(fs.readFileSync(file, 'utf8'));
const index = fixture.index ?? 0;
const response = fixture.responses[index];
fixture.index = index + 1;
fs.writeFileSync(file, JSON.stringify(fixture));
if (fixture.errorAt === index) process.exit(1);
if (fixture.malformedAt === index) { console.log('{bad json'); process.exit(0); }
if (JSON.stringify(process.argv.slice(2)) !== JSON.stringify(['api', '--hostname', 'github.com', response.endpoint])) {
  console.error('Unexpected API request'); process.exit(2);
}
console.log(JSON.stringify(response.body));
`, { mode: 0o755 });
    const evidence = path.join(dir, 'evidence.json');
    const output = path.join(dir, 'output');
    const result = spawnSync(process.execPath, [helper, '--sha', source, '--output', evidence], {
      cwd: root, encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`,
        CI_FIXTURE: path.join(dir, 'fixture.json'), GITHUB_REPOSITORY: repository, GITHUB_OUTPUT: output },
    });
    return { ...result, evidence: existsSync(evidence) ? JSON.parse(readFileSync(evidence)) : null,
      output: existsSync(output) ? readFileSync(output, 'utf8') : '' };
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

function rejected(options) {
  const result = invoke(options);
  assert.notEqual(result.status, 0);
  assert.equal(result.evidence, null);
  assert.equal(result.output, '');
  assert.match(result.stderr, /CI evidence rejected/);
}

for (const event of ['push', 'workflow_dispatch']) {
  test(`accepts trusted ${event} and retains exact run evidence`, () => {
    const trusted = { ...run, event };
    const result = invoke({ runs: [trusted], current: trusted });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(result.evidence, { repository: repo, workflow_id: workflow, workflow_path: run.path,
      run_id: run.id, run_url: `https://github.com/${repo}/actions/runs/${run.id}/attempts/2`,
      run_attempt: 2, head_sha: sha, head_branch: 'main', event, status: 'completed', conclusion: 'success' });
    assert.equal(result.output, `verified_sha=${sha}\n`);
  });
}

for (const patch of [
  { head_sha: '0'.repeat(40) }, { workflow_id: 42 }, { path: '.github/workflows/other.yml' },
  { head_branch: 'feature' }, { event: 'pull_request' }, { event: 'pull_request_target' },
  { repository: { full_name: 'other/repo' } }, { head_repository: { full_name: 'fork/toastty' } },
]) {
  test(`rejects untrusted identity ${JSON.stringify(patch)}`, () => {
    const invalid = { ...run, ...patch };
    rejected({ runs: [invalid], current: invalid });
    rejected({ current: invalid });
  });
}
for (const conclusion of ['failure', 'skipped', 'cancelled', 'abandoned', 'neutral', 'timed_out', null]) {
  test(`rejects run and gate result ${conclusion}`, () => {
    rejected({ current: { ...run, conclusion } });
    rejected({ jobs: [{ ...gate, conclusion }] });
  });
}
for (const status of ['queued', 'in_progress', 'waiting', 'requested']) {
  test(`rejects pending ${status} even with stale success conclusion`, () => {
    rejected({ current: { ...run, status } });
    rejected({ jobs: [{ ...gate, status }] });
  });
}

test('rejects missing, duplicate or mismatched gate evidence', () => {
  rejected({ runs: [] });
  rejected({ jobs: [] });
  rejected({ jobs: [gate, gate] });
  for (const patch of [{ run_id: 9 }, { run_attempt: 1 }, { head_sha: '0'.repeat(40) }]) {
    rejected({ jobs: [{ ...gate, ...patch }] });
  }
});
test('does not use older green runs or historical attempts', () => {
  const older = { ...run, id: 100, run_number: 9 };
  rejected({ runs: [older, run], current: { ...run, status: 'queued', conclusion: null } });
  rejected({ runs: [older, run], current: { ...run, conclusion: 'failure' } });
  rejected({ final: { ...run, run_attempt: 3, status: 'queued', conclusion: null } });
  rejected({ final: { ...run, run_attempt: 3 } });
  rejected({ final: { ...run, conclusion: 'failure' } });
});
test('fails closed for unavailable, malformed or incomplete API results', () => {
  for (let i = 0; i < 4; i++) { rejected({ errorAt: i }); rejected({ malformedAt: i }); }
  rejected({ total: 101 });
  rejected({ jobTotal: 101 });
  rejected({ total: 0 });
});
test('requires exact checked-out source and repository', () => {
  rejected({ source: '0'.repeat(40) });
  rejected({ source: 'main' });
  rejected({ repository: 'fork/toastty' });
});

test('ignores a newer PR run even when its source SHA and branch match', () => {
  const result = invoke({ runs: [{ ...run, id: 999, run_number: 99, event: 'pull_request' }, run] });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.evidence.run_id, run.id);
});
