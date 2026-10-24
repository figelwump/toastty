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
  ['Sources/App/SidebarView.swift', []],
  ['Sources/Core/Sessions/SessionStatus.swift', []],
  ['Tests/App/ExampleTests.swift', []],
  ['ios/Sources/ToasttyMobileApp/Example.swift', ['scripts']],
  ['ios/scripts/toastty-ios.mjs', ['scripts']],
  ['ios/Tests/ReleaseScriptTests/require-ios-ci.test.mjs', ['scripts']],
  ['Sources/RemoteProtocol/RemoteSessionModels.swift', []],
  ['WebPanels/LocalDocumentApp/src/index.jsx', ['web']],
  ['WebPanels/ScratchpadApp/package-lock.json', ['web']],
  ['Sources/App/Resources/WebPanels/scratchpad-panel/index.html', ['web']],
  ['Tests/RemoteScripts/RunnerWrapperTests.mjs', ['scripts']],
  ['scripts/dev/bootstrap-worktree.sh', ['scripts']],
  ['scripts/remote/test.sh', ['scripts']],
  ['.github/workflows/mobile-ios.yml', ['scripts', 'web']],
  ['.github/workflows/ios-testflight.yml', ['scripts']],
  ['.github/ci-paths.yml', ['scripts', 'web']],
  ['Tests/CI/workflow.test.mjs', ['scripts', 'web']],
  ['.secrets', ['scripts']],
  ['.node-version', ['scripts', 'web']],
  ['.tool-versions', ['scripts', 'web']],
  ['.github/ios-xcode-version', ['scripts']],
  ['.github/ios-release-ci-jobs.json', ['scripts']],
  ['docs/remote-access.md', []],
  ['README.md', []],
]) {
  test(`selects applicable Linux checks for ${path}`, () => {
    assert.deepEqual(selected(path), expected);
  });
}

test('only PR runs cancel superseded runs', () => {
  assert.equal(workflow.concurrency['cancel-in-progress'], "${{ github.event_name == 'pull_request' }}");
  // run_id rather than sha: two runs of one commit must not replace each other while pending.
  assert.ok(workflow.concurrency.group.includes("github.event_name == 'pull_request' && github.ref || github.run_id"));
});

test('every PR gets a gate and full validation remains manual without main reruns', () => {
  assert.ok(Object.hasOwn(workflow.on, 'pull_request'));
  assert.equal(workflow.on.pull_request, null);
  assert.equal(Object.hasOwn(workflow.on, 'push'), false);
  for (const path of ['.github/workflows/push-worker.yml', '.github/workflows/ios-testflight.yml']) {
    assert.equal(Object.hasOwn(parse(read(path)).on, 'push'), false, path);
  }
  assert.ok(Object.hasOwn(workflow.on, 'workflow_dispatch'));
  // Branch protection on main requires this exact check name.
  assert.equal(workflow.jobs.gate.name, 'CI gate');
  assert.equal(workflow.jobs.gate.if, 'always()');
  assert.deepEqual([...workflow.jobs.gate.needs].sort(), ['changes', 'ios', 'macos', 'scripts', 'web']);
});

test('selection outputs drive each job and use the tested filters', () => {
  const filter = workflow.jobs.changes.steps.find((step) => step.id === 'filter');
  assert.equal(filter.with.filters, '.github/ci-paths.yml');
  assert.equal(filter.if, "github.event_name == 'pull_request'");
  for (const name of ['scripts', 'web']) {
    assert.equal(workflow.jobs.changes.outputs[name], `\${{ steps.filter.outputs.${name} }}`);
    assert.equal(workflow.jobs[name].if,
      `github.event_name == 'workflow_dispatch' || needs.changes.outputs.${name} == 'true'`);
  }
  for (const name of ['ios', 'macos']) {
    assert.equal(workflow.jobs[name].if, "github.event_name == 'workflow_dispatch'");
  }
});

const gateStep = workflow.jobs.gate.steps[0];
const gate = (overrides = {}) => spawnSync('bash', ['-e', '-o', 'pipefail', '-c', gateStep.run], {
  env: { ...process.env, CHANGES_RESULT: 'success', FULL_RUN: 'false',
    SCRIPTS_SELECTED: 'false', WEB_SELECTED: 'false',
    IOS_RESULT: 'skipped', MACOS_RESULT: 'skipped', SCRIPTS_RESULT: 'skipped', WEB_RESULT: 'skipped', ...overrides },
  encoding: 'utf8',
});

test('gate accepts documentation-only changes and completed selected jobs', () => {
  assert.equal(gate().status, 0);
  assert.equal(gate({ SCRIPTS_SELECTED: 'true', SCRIPTS_RESULT: 'success' }).status, 0);
});

test('gate rejects failed selection and any failed or cancelled job', () => {
  for (const state of ['failure', 'cancelled', 'skipped']) {
    assert.notEqual(gate({ CHANGES_RESULT: state }).status, 0);
  }
  for (const name of ['IOS', 'MACOS', 'SCRIPTS', 'WEB']) {
    for (const state of ['failure', 'cancelled']) {
      assert.notEqual(gate({ [`${name}_RESULT`]: state }).status, 0);
    }
    if (['SCRIPTS', 'WEB'].includes(name)) {
      assert.notEqual(gate({ [`${name}_SELECTED`]: 'true' }).status, 0);
    }
  }
});

test('PR gate rejects absent or malformed selection outputs', () => {
  for (const name of ['SCRIPTS_SELECTED', 'WEB_SELECTED']) {
    for (const value of ['', 'yes', 'undefined']) {
      assert.notEqual(gate({ [name]: value }).status, 0);
    }
  }
});

test('release evidence job names match the full manual workflow', () => {
  const names = Object.entries(workflow.jobs).filter(([id]) => id !== 'changes').flatMap(([, job]) => {
    const configurations = job.strategy?.matrix.configuration;
    return configurations ? configurations.map((configuration) =>
      job.name.replace('${{ matrix.configuration }}', configuration)) : [job.name];
  });
  assert.deepEqual(JSON.parse(read('.github/ios-release-ci-jobs.json')).sort(), names.sort());
});

test('manual full validation requires every job to pass', () => {
  assert.notEqual(gate({ FULL_RUN: 'true' }).status, 0);
  // Path selection is skipped outside PRs, so its outputs arrive empty.
  const unselected = { SCRIPTS_SELECTED: '', WEB_SELECTED: '' };
  assert.notEqual(gate({ FULL_RUN: 'true', ...unselected, MACOS_RESULT: 'success' }).status, 0);
  assert.equal(gate({ FULL_RUN: 'true', ...unselected, IOS_RESULT: 'success',
    MACOS_RESULT: 'success', SCRIPTS_RESULT: 'success', WEB_RESULT: 'success' }).status, 0);
  assert.equal(gate({ FULL_RUN: 'true', IOS_RESULT: 'success',
    MACOS_RESULT: 'success', SCRIPTS_RESULT: 'success', WEB_RESULT: 'success' }).status, 0);
});

test('manual native validation retains both configurations, full UI, and performance budgets', () => {
  const iosJob = workflow.jobs.ios;
  assert.deepEqual(iosJob.strategy.matrix.configuration, ['Debug', 'Release']);
  const command = iosJob.steps.find((step) => step.name === 'Test native client').run;
  assert.equal(command, 'node ios/scripts/toastty-ios.mjs test --retry-tests-on-failure');
  for (const configuration of ['Debug', 'Release']) {
    const result = spawnSync(process.execPath, [
      new URL('ios/scripts/toastty-ios.mjs', root).pathname,
      'test', '--retry-tests-on-failure', '--dry-run',
    ], {
      env: { ...process.env, TOASTTY_IOS_CONFIGURATION: configuration }, encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    const args = JSON.parse(result.stdout).steps.at(-1).args;
    assert.ok(!args.some((arg) => arg.startsWith('-skip-testing:')));
    assert.ok(!args.some((arg) => arg.startsWith('-only-testing:ToasttyMobileUITests/')));
    assert.deepEqual(args.slice(-4), ['-retry-tests-on-failure', '-test-iterations', '2', 'test']);
  }
});

test('script fixtures run on Linux or manual Mac without losing test files', () => {
  const job = workflow.jobs.scripts;
  assert.equal(job['runs-on'], 'ubuntu-latest');
  const command = job.steps.find((step) => step.run).run;
  for (const directory of ['ios/Tests/ScriptTests', 'ios/Tests/ReleaseScriptTests', 'Tests/RemoteScripts']) {
    assert.ok(command.includes(`${directory}/`));
  }
  assert.ok(!job.steps.some((step) => /tuist|xcodebuild/.test(step.run ?? '')));
  assert.ok(!command.includes('ios-testflight.test.mjs'));
  assert.ok(!command.includes('validate-device-build.test.mjs'));
  const macCommand = workflow.jobs.macos.steps.find((step) => step.name === 'Test Mac release and device scripts').run;
  const globs = `${command} ${macCommand}`.split(/\s+/).filter((part) => part.endsWith('.mjs'));
  for (const directory of ['ios/Tests/ScriptTests', 'ios/Tests/ReleaseScriptTests', 'Tests/RemoteScripts']) {
    for (const entry of readdirSync(new URL(`${directory}/`, root), { withFileTypes: true })) {
      if (entry.isFile() && entry.name.endsWith('.mjs')) {
        assert.ok(picomatch(globs)(`${directory}/${entry.name}`), `Uncovered fixture: ${directory}/${entry.name}`);
      }
    }
  }
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

const releaseWorkflow = parse(read('.github/workflows/ios-testflight.yml'));
test('TestFlight requires exact-source CI before signed archive and has no test bypass', () => {
  const job = releaseWorkflow.jobs.testflight;
  assert.deepEqual(Object.keys(releaseWorkflow.jobs), ['testflight']);
  assert.deepEqual(Object.keys(releaseWorkflow.on.workflow_dispatch.inputs), ['upload']);
  assert.deepEqual(job.permissions, { contents: 'read', actions: 'read' });
  assert.deepEqual(Object.keys(releaseWorkflow.on), ['workflow_dispatch']);
  assert.equal(job.if, undefined);
  const checkout = job.steps.find((step) => step.uses?.startsWith('actions/checkout@'));
  assert.equal(checkout.with.ref, '${{ github.sha }}');
  const gateIndex = job.steps.findIndex((step) => step.id === 'ci');
  const archiveIndex = job.steps.findIndex((step) => step.name === 'Archive and validate TestFlight build');
  assert.ok(gateIndex > 0 && archiveIndex > gateIndex);
  const gate = job.steps[gateIndex];
  assert.equal(gate.if, undefined);
  assert.equal(gate['continue-on-error'], undefined);
  assert.equal(gate.env.GH_TOKEN, '${{ github.token }}');
  assert.equal(gate.env.RELEASE_SHA, '${{ github.sha }}');
  assert.equal(gate.run, 'node scripts/ci/require-ios-ci.mjs --sha "$RELEASE_SHA" --output artifacts/ios-release/ci-evidence.json');
  const archive = job.steps[archiveIndex];
  assert.equal(archive.env.TOASTTY_IOS_VERIFIED_SHA, '${{ steps.ci.outputs.verified_sha }}');
  assert.equal(archive.if, undefined);
  assert.ok(!job.steps.some((step) => step.run?.includes('toastty-ios.mjs test')));
  const upload = job.steps.find((step) => step.uses?.startsWith('actions/upload-artifact@'));
  assert.ok(upload.with.path.split('\n').includes('artifacts/ios-release/ci-evidence.json'));
  assert.equal(upload.with['retention-days'], 90);
});

test('iOS CI and archiving select the same pinned Xcode before generation', () => {
  for (const job of [workflow.jobs.ios, releaseWorkflow.jobs.testflight]) {
    assert.equal(job['runs-on'], 'macos-26');
    const pin = job.steps.findIndex((step) => step.run === 'bash scripts/ci/select-ios-xcode.sh');
    const install = job.steps.findIndex((step) => step.name === 'Install pinned Tuist');
    assert.ok(pin >= 0 && install > pin);
  }
  assert.deepEqual(selected('.github/ios-xcode-version'), ['scripts']);
  for (const script of ['require-ios-ci.mjs', 'select-ios-xcode.sh', 'ios-testflight.sh']) {
    assert.deepEqual(selected(`scripts/ci/${script}`), ['scripts']);
  }
});

test('full CI gate blocks every non-success graph result, including abandoned runners', () => {
  for (const name of ['IOS', 'MACOS', 'SCRIPTS', 'WEB']) {
    for (const result of ['skipped', 'failure', 'cancelled', 'abandoned', '', 'pending']) {
      assert.notEqual(gate({ FULL_RUN: 'true', IOS_RESULT: 'success', MACOS_RESULT: 'success',
        WEB_RESULT: 'success', [`${name}_RESULT`]: result }).status, 0);
    }
  }
});
