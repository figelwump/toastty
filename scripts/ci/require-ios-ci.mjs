#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { appendFileSync, mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { fileURLToPath } from 'node:url';

const repository = 'figelwump/toastty';
const workflowID = 340799440;
const workflowPath = '.github/workflows/mobile-ios.yml';
const trustedEvents = ['push', 'workflow_dispatch'];
const root = fileURLToPath(new URL('../../', import.meta.url));
const positiveInteger = (value) => Number.isSafeInteger(value) && value > 0;
function requireEvidence(condition, message) {
  if (!condition) throw new Error(message);
}
function api(endpoint) {
  try {
    return JSON.parse(execFileSync('gh', ['api', '--hostname', 'github.com', endpoint], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000,
    }));
  } catch {
    // Do not print authentication or raw API output in release logs.
    throw new Error('GitHub Actions API is unavailable or returned invalid JSON.');
  }
}
function completeList(response, key) {
  requireEvidence(Array.isArray(response?.[key]) && Number.isSafeInteger(response.total_count)
    && response.total_count === response[key].length && response.total_count <= 100,
  `Incomplete ${key} evidence; refusing a truncated result.`);
  return response[key];
}
function validateRun(run, sha) {
  requireEvidence(run?.workflow_id === workflowID && run.path === workflowPath
    && run.repository?.full_name === repository && run.head_repository?.full_name === repository
    && run.head_sha === sha && run.head_branch === 'main' && trustedEvents.includes(run.event)
    && positiveInteger(run.id) && positiveInteger(run.run_number) && positiveInteger(run.run_attempt),
  'Run identity does not match trusted Toastty CI on main at the checked-out SHA.');
}
function requireSuccess(result) {
  requireEvidence(result?.status === 'completed' && result.conclusion === 'success',
    'The latest trusted CI run and its CI gate must be completed/success.');
}

try {
  const { values } = parseArgs({ options: { sha: { type: 'string' }, output: { type: 'string' } } });
  requireEvidence(/^[a-f0-9]{40}$/.test(values.sha ?? '') && values.output, 'Provide --sha COMMIT and --output PATH.');
  requireEvidence(process.env.GITHUB_REPOSITORY === repository, 'Unexpected release repository.');
  const head = execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  requireEvidence(head === values.sha, 'Checked-out source differs from the release SHA.');
  const prefix = `repos/${repository}/actions`;
  // Never filter by success: a newer failed/pending run must block older green evidence.
  const runs = completeList(api(`${prefix}/workflows/${workflowID}/runs?branch=main&head_sha=${head}&per_page=100`), 'workflow_runs')
    .filter((run) => trustedEvents.includes(run.event));
  requireEvidence(runs.length > 0, 'No trusted main CI run exists for this source.');
  for (const run of runs) validateRun(run, head);
  runs.sort((left, right) => right.run_number - left.run_number);
  const selected = runs[0];
  const endpoint = `${prefix}/runs/${selected.id}`;
  const current = api(endpoint);
  validateRun(current, head);
  requireEvidence(current.id === selected.id && current.run_number === selected.run_number,
    'Current run differs from the selected run.');
  requireSuccess(current);
  const jobs = completeList(api(`${endpoint}/attempts/${current.run_attempt}/jobs?per_page=100`), 'jobs');
  // Main CI gate already requires every graph, including both native configurations.
  const gates = jobs.filter((job) => job.name === 'CI gate');
  requireEvidence(gates.length === 1 && gates[0].run_id === current.id
    && gates[0].run_attempt === current.run_attempt && gates[0].head_sha === head,
  'Missing or mismatched CI gate for the current run attempt.');
  requireSuccess(gates[0]);
  const latest = api(endpoint);
  validateRun(latest, head);
  requireEvidence(latest.id === current.id && latest.run_attempt === current.run_attempt,
    'CI was rerun while checking evidence; retry after it finishes.');
  requireSuccess(latest);
  const evidence = {
    repository, workflow_id: workflowID, workflow_path: workflowPath,
    run_id: current.id,
    run_url: `https://github.com/${repository}/actions/runs/${current.id}/attempts/${current.run_attempt}`,
    run_attempt: current.run_attempt, head_sha: head, head_branch: current.head_branch,
    event: current.event, status: current.status, conclusion: current.conclusion,
  };
  mkdirSync(path.dirname(values.output), { recursive: true });
  writeFileSync(values.output, `${JSON.stringify(evidence, null, 2)}\n`);
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `verified_sha=${head}\n`);
  console.log(`Trusted CI verified: ${evidence.run_url} at ${head}`);
} catch (error) {
  console.error(`CI evidence rejected: ${error.message}\nWait for successful Toastty CI on this exact main commit, then retry TestFlight. No tests were dispatched.`);
  process.exitCode = 1;
}
