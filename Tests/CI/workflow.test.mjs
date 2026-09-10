import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import picomatch from 'picomatch';
import { parse } from 'yaml';

const root = new URL('../../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');
const workflow = parse(read('.github/workflows/mobile-ios.yml'));
const filters = parse(read('.github/ci-paths.yml'));
const selected = (path) => Object.entries(filters)
  .filter(([, patterns]) => picomatch(patterns, { dot: true })(path))
  .map(([name]) => name).sort();

for (const [path, expected] of [
  ['Sources/App/SidebarView.swift', ['macos']],
  ['Sources/Core/Sessions/SessionStatus.swift', ['macos']],
  ['Sources/CLI/main.swift', ['macos']],
  ['Sources/App/.fixtures/example.json', ['macos']],
  ['Tests/App/ExampleTests.swift', ['macos']],
  ['Tests/Core/ExampleTests.swift', ['macos']],
  ['ios/Sources/ToasttyMobileApp/Example.swift', ['ios']],
  ['ios/Project.swift', ['ios']],
  ['Sources/RemoteProtocol/RemoteSessionModels.swift', ['ios', 'macos']],
  ['Tests/RemoteProtocol/Fixtures/example.json', ['ios', 'macos']],
  ['WebPanels/LocalDocumentApp/src/index.jsx', ['ios', 'macos', 'web']],
  ['WebPanels/ScratchpadApp/package-lock.json', ['ios', 'macos', 'web']],
  ['Sources/App/Resources/WebPanels/scratchpad-panel/index.html', ['ios', 'macos', 'web']],
  ['Tuist/Package.resolved', ['macos']],
  ['Project.swift', ['macos']],
  ['scripts/dev/bootstrap-worktree.sh', ['macos']],
  ['scripts/remote/test.sh', ['ios', 'macos']],
  ['.github/workflows/mobile-ios.yml', ['ios', 'macos', 'web']],
  ['.github/ci-paths.yml', ['ios', 'macos', 'web']],
  ['Tests/CI/workflow.test.mjs', ['ios', 'macos', 'web']],
  ['.node-version', ['ios', 'macos', 'web']],
  ['docs/remote-access.md', []],
  ['README.md', []],
]) {
  test(`selects applicable checks for ${path}`, () => {
    assert.deepEqual(selected(path), expected);
  });
}

test('every PR gets a gate; pushes target main and manual runs remain available', () => {
  assert.ok(Object.hasOwn(workflow.on, 'pull_request'));
  assert.equal(workflow.on.pull_request, null);
  assert.deepEqual(workflow.on.push, { branches: ['main'] });
  assert.ok(Object.hasOwn(workflow.on, 'workflow_dispatch'));
  assert.equal(workflow.jobs.gate.name, 'Mobile iOS gate');
  assert.equal(workflow.jobs.gate.if, 'always()');
  assert.deepEqual([...workflow.jobs.gate.needs].sort(), ['changes', 'ios', 'macos', 'web']);
});

test('selection outputs drive each job and use the tested filters', () => {
  const filter = workflow.jobs.changes.steps.find((step) => step.id === 'filter');
  assert.equal(filter.with.filters, '.github/ci-paths.yml');
  assert.equal(filter.if, "github.event_name != 'workflow_dispatch'");
  for (const name of ['ios', 'macos', 'web']) {
    assert.equal(workflow.jobs.changes.outputs[name], `\${{ steps.filter.outputs.${name} }}`);
    assert.equal(workflow.jobs[name].if,
      `github.event_name == 'workflow_dispatch' || needs.changes.outputs.${name} == 'true'`);
  }
});

const gateStep = workflow.jobs.gate.steps[0];
const gate = (overrides = {}) => spawnSync('bash', ['-e', '-o', 'pipefail', '-c', gateStep.run], {
  env: { ...process.env, CHANGES_RESULT: 'success', MANUAL_RUN: 'false',
    IOS_SELECTED: 'false', MACOS_SELECTED: 'false', WEB_SELECTED: 'false',
    IOS_RESULT: 'skipped', MACOS_RESULT: 'skipped', WEB_RESULT: 'skipped', ...overrides },
  encoding: 'utf8',
});

test('gate accepts documentation-only changes and completed selected jobs', () => {
  assert.equal(gate().status, 0);
  assert.equal(gate({ MACOS_SELECTED: 'true', MACOS_RESULT: 'success' }).status, 0);
});

test('gate rejects failed selection and any failed or cancelled job', () => {
  for (const state of ['failure', 'cancelled', 'skipped']) {
    assert.notEqual(gate({ CHANGES_RESULT: state }).status, 0);
  }
  for (const name of ['IOS', 'MACOS', 'WEB']) {
    for (const state of ['failure', 'cancelled']) {
      assert.notEqual(gate({ [`${name}_RESULT`]: state }).status, 0);
    }
    assert.notEqual(gate({ [`${name}_SELECTED`]: 'true' }).status, 0);
  }
});

test('manual runs require every job to pass', () => {
  assert.notEqual(gate({ MANUAL_RUN: 'true' }).status, 0);
  assert.equal(gate({ MANUAL_RUN: 'true', IOS_RESULT: 'success',
    MACOS_RESULT: 'success', WEB_RESULT: 'success' }).status, 0);
});


test('every web-panel package is covered by the web test command', () => {
  const command = workflow.jobs.web.steps.find((step) => step.run).run;
  for (const entry of readdirSync(new URL('WebPanels/', root), { withFileTypes: true })) {
    const path = `WebPanels/${entry.name}`;
    if (entry.isDirectory() && existsSync(new URL(`${path}/package.json`, root))) {
      assert.ok(command.includes(path), `Add ${path} to the web-panel CI command`);
    }
  }
});

test('Mac artifacts include result bundles without uploading DerivedData', () => {
  const upload = workflow.jobs.macos.steps.find((step) => step.uses?.startsWith('actions/upload-artifact@'));
  assert.equal(upload.with.path, 'artifacts/ci-macos/*.xcresult');
});
