import assert from 'node:assert/strict';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import picomatch from 'picomatch';
import { parse } from 'yaml';

const root = new URL('../../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');
const workflow = parse(read('.github/workflows/mobile-ios.yml'));
test('only PR runs cancel superseded runs', () => {
  assert.equal(workflow.concurrency['cancel-in-progress'], "${{ github.event_name == 'pull_request' }}");
  // run_id rather than sha: two runs of one commit must not replace each other while pending.
  assert.ok(workflow.concurrency.group.includes("github.event_name == 'pull_request' && github.ref || github.run_id"));
});

test('pull requests require desktop validation and keep full iOS and auxiliary jobs manual', () => {
  assert.deepEqual(Object.keys(workflow.on).sort(), ['pull_request', 'workflow_dispatch']);
  assert.equal(workflow.on.pull_request, null);
  for (const path of ['.github/workflows/push-worker.yml', '.github/workflows/ios-testflight.yml']) {
    assert.deepEqual(Object.keys(parse(read(path)).on), ['workflow_dispatch'], path);
  }
  // Branch protection on main requires this exact check name.
  assert.equal(workflow.jobs.gate.name, 'CI gate');
  assert.equal(workflow.jobs.gate.if, 'always()');
  assert.equal(workflow.jobs.workflow.if, undefined);
  assert.equal(workflow.jobs.workflow['runs-on'], 'ubuntu-latest');
  for (const name of ['ios', 'scripts', 'web']) {
    assert.equal(workflow.jobs[name].if, "github.event_name == 'workflow_dispatch'", name);
    assert.equal(workflow.jobs[name].needs, 'workflow', name);
  }
  assert.equal(workflow.jobs.ios.permissions.contents, 'read');
  for (const name of ['macos', 'linux']) {
    assert.equal(workflow.jobs[name].if, undefined, name);
    assert.equal(workflow.jobs[name].needs, 'workflow', name);
    assert.deepEqual(workflow.jobs[name].permissions, { contents: 'read' });
    assert.equal(workflow.jobs[name].steps[0].with['persist-credentials'], false);
  }
  assert.deepEqual([...workflow.jobs.gate.needs].sort(), ['ios', 'linux', 'macos', 'scripts', 'web', 'workflow']);
});

const gateStep = workflow.jobs.gate.steps[0];
const gate = (overrides = {}) => spawnSync('bash', ['-e', '-o', 'pipefail', '-c', gateStep.run], {
  env: { ...process.env, WORKFLOW_RESULT: 'success', FULL_RUN: 'false',
    IOS_RESULT: 'skipped', MACOS_RESULT: 'success', LINUX_RESULT: 'success', SCRIPTS_RESULT: 'skipped', WEB_RESULT: 'skipped', ...overrides },
  encoding: 'utf8',
});

test('PR gate requires workflow and desktop success and keeps manual jobs skipped', () => {
  assert.equal(gate().status, 0);
  for (const name of ['WORKFLOW', 'MACOS', 'LINUX']) {
    for (const state of ['failure', 'cancelled', 'skipped', '']) {
      assert.notEqual(gate({ [`${name}_RESULT`]: state }).status, 0);
    }
  }
  for (const name of ['IOS', 'SCRIPTS', 'WEB']) {
    for (const state of ['success', 'failure', 'cancelled', '']) {
      assert.notEqual(gate({ [`${name}_RESULT`]: state }).status, 0);
    }
  }
});

test('release evidence job names match the full manual workflow', () => {
  const names = Object.entries(workflow.jobs).filter(([id]) => id !== 'workflow').flatMap(([, job]) => {
    const matrix = job.strategy?.matrix;
    if (!matrix) return [job.name];
    const [[key, values]] = Object.entries(matrix);
    return values.map((value) => job.name.replace(`\${{ matrix.${key} }}`, value));
  });
  assert.deepEqual(JSON.parse(read('.github/ios-release-ci-jobs.json')).sort(), names.sort());
});

test('manual full validation requires every job to pass', () => {
  assert.notEqual(gate({ FULL_RUN: 'true' }).status, 0);
  assert.equal(gate({ FULL_RUN: 'true', IOS_RESULT: 'success',
    MACOS_RESULT: 'success', SCRIPTS_RESULT: 'success', WEB_RESULT: 'success' }).status, 0);
  assert.notEqual(gate({ FULL_RUN: 'true', WORKFLOW_RESULT: 'failure', IOS_RESULT: 'success',
    MACOS_RESULT: 'success', SCRIPTS_RESULT: 'success', WEB_RESULT: 'success' }).status, 0);
});

test('manual native validation retains both configurations, full UI, and performance budgets', () => {
  const iosJob = workflow.jobs.ios;
  assert.deepEqual(iosJob.strategy.matrix.configuration, ['Debug', 'Release']);
  const full = iosJob.steps.find((step) => step.name === 'Test native client');
  assert.equal(full.if, undefined);
  assert.equal(full.run, 'node ios/scripts/toastty-ios.mjs test --retry-tests-on-failure');
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

test('hosted Mac runs Ghostty-backed Debug tests, a Release build, and GUI smoke', () => {
  const job = workflow.jobs.macos;
  assert.equal(job['runs-on'], 'macos-26');
  assert.equal(job.env.TUIST_DISABLE_GHOSTTY, undefined);
  assert.equal(job.env.TUIST_TOASTTY_DISABLE_PUSH, 1);
  assert.ok(job.steps.some((step) => step.run?.includes('build-macos-ghostty.sh')));
  assert.ok(job.steps.some((step) => step.run?.includes('grep -q TOASTTY_HAS_GHOSTTY_KIT')));
  assert.match(job.steps.find((step) => step.id === 'debug-build').run, /-configuration Debug[\s\S]+build-for-testing$/m);
  const tests = job.steps.find((step) => step.name === 'Run macOS XCTest');
  assert.match(tests.run, /-parallel-testing-enabled NO[\s\S]+test-without-building$/m);
  assert.match(job.steps.find((step) => step.name.includes('Release app')).run, /-configuration Release[\s\S]+build$/m);
  const smoke = job.steps.find((step) => step.name === 'Smoke test the macOS GUI');
  assert.match(smoke.if, /steps\.debug-build\.outcome == 'success'/);
  for (const script of ['smoke-ui', 'workspace-tabs-smoke', 'workspace-scope-smoke', 'shortcut-hints-smoke']) {
    assert.ok(smoke.run.includes(script));
  }
  const upload = job.steps.find((step) => step.uses?.startsWith('actions/upload-artifact@'));
  assert.equal(upload.if, 'always()');
  assert.deepEqual(upload.with.path.trim().split('\n'), [
    'artifacts/ci-macos/*.xcresult',
    'artifacts/dev-runs/ci-*/artifacts/',
  ]);
});

test('Linux uses native 24.04 and 26.04 runners and keeps both results', () => {
  const job = workflow.jobs.linux;
  assert.equal(job['runs-on'], '${{ matrix.runner }}');
  assert.deepEqual(job.strategy.matrix.runner, ['ubuntu-24.04', 'ubuntu-26.04']);
  assert.equal(job.strategy['fail-fast'], false);
  assert.ok(job.steps.some((step) => step.run === 'linux/ghostty/build-libghostty.sh'));
  const desktopGate = job.steps.find((step) => step.run?.includes('dbus-run-session -- scripts/linux/check.sh'));
  assert.equal(desktopGate.env.APPIMAGE_EXTRACT_AND_RUN, 1);
  assert.equal(job.steps.find((step) => step.uses?.startsWith('actions/upload-artifact@')).if, 'always()');
});

test('Ghostty installer works in a fresh checkout without Dependencies', (t) => {
  const checkout = mkdtempSync(join(tmpdir(), 'toastty-ghostty-install-'));
  t.after(() => rmSync(checkout, { recursive: true, force: true }));
  const script = join(checkout, 'scripts/ghostty/install-local-xcframework.sh');
  const framework = join(checkout, 'fixture/GhosttyKit.xcframework');
  mkdirSync(join(checkout, 'scripts/ghostty'), { recursive: true });
  mkdirSync(framework, { recursive: true });
  copyFileSync(new URL('scripts/ghostty/install-local-xcframework.sh', root), script);
  writeFileSync(join(framework, 'Info.plist'), 'framework fixture\n');

  const result = spawnSync('bash', [script], {
    env: {
      ...process.env,
      GHOSTTY_XCFRAMEWORK_SOURCE: framework,
      GHOSTTY_XCFRAMEWORK_VARIANT: 'debug',
      GHOSTTY_COMMIT: '0123456789012345678901234567890123456789',
      GHOSTTY_SOURCE_DIRTY: '0',
      GHOSTTY_BUILD_FLAGS: '-Demit-xcframework=true',
    },
    encoding: 'utf8',
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(join(checkout, 'Dependencies/GhosttyKit.Debug.xcframework/Info.plist'), 'utf8'), 'framework fixture\n');
  assert.match(readFileSync(join(checkout, 'Dependencies/GhosttyKit.Debug.metadata.env'), 'utf8'), /GHOSTTY_COMMIT=0123456789012345678901234567890123456789/);
});

const releaseWorkflow = parse(read('.github/workflows/ios-testflight.yml'));
test('TestFlight builds a main commit with exact-source CI or a recorded override', () => {
  const job = releaseWorkflow.jobs.testflight;
  assert.deepEqual(Object.keys(releaseWorkflow.jobs), ['testflight']);
  const inputs = releaseWorkflow.on.workflow_dispatch.inputs;
  assert.deepEqual(Object.keys(inputs), ['upload', 'source_sha', 'ci_override_reason']);
  for (const name of ['source_sha', 'ci_override_reason']) {
    assert.equal(inputs[name].required, false);
    assert.equal(inputs[name].default, '');
  }
  assert.deepEqual(job.permissions, { contents: 'read', actions: 'read' });
  assert.deepEqual(Object.keys(releaseWorkflow.on), ['workflow_dispatch']);
  assert.equal(job.if, undefined);
  const index = (predicate) => job.steps.findIndex(predicate);
  const sourceIndex = index((step) => step.id === 'source');
  const checkoutIndex = index((step) => step.uses?.startsWith('actions/checkout@'));
  const onMainIndex = index((step) => step.name === 'Require release source on main');
  const gateIndex = index((step) => step.id === 'ci');
  const archiveIndex = index((step) => step.name === 'Archive and validate TestFlight build');
  assert.ok(sourceIndex === 0 && checkoutIndex > sourceIndex && onMainIndex > checkoutIndex
    && gateIndex > onMainIndex && archiveIndex > gateIndex);
  const source = job.steps[sourceIndex];
  assert.deepEqual(source.env, { REQUESTED_SHA: '${{ inputs.source_sha }}', EVENT_SHA: '${{ github.sha }}' });
  const checkout = job.steps[checkoutIndex];
  assert.equal(checkout.with.ref, '${{ steps.source.outputs.sha }}');
  assert.equal(checkout.with['fetch-depth'], 0);
  const onMain = job.steps[onMainIndex];
  assert.equal(onMain.if, undefined);
  assert.match(onMain.run, /git merge-base --is-ancestor "\$SOURCE_SHA" refs\/remotes\/origin\/main/);
  const gate = job.steps[gateIndex];
  assert.equal(gate.if, undefined);
  assert.equal(gate['continue-on-error'], undefined);
  assert.equal(gate.env.GH_TOKEN, '${{ github.token }}');
  assert.equal(gate.env.GATE_SHA, '${{ github.sha }}');
  assert.equal(gate.env.RELEASE_SHA, '${{ steps.source.outputs.sha }}');
  assert.equal(gate.env.CI_OVERRIDE_REASON, '${{ inputs.ci_override_reason }}');
  // The gate script and its job list come from the dispatched commit, not the checked-out source.
  assert.match(gate.run, /git show "\$GATE_SHA:scripts\/ci\/require-ios-ci\.mjs" > "\$gate\/scripts\/ci\/require-ios-ci\.mjs"/);
  assert.match(gate.run, /git show "\$GATE_SHA:\.github\/ios-release-ci-jobs\.json" > "\$gate\/\.github\/ios-release-ci-jobs\.json"/);
  assert.match(gate.run, /node "\$gate\/scripts\/ci\/require-ios-ci\.mjs" --source "\$GITHUB_WORKSPACE" --sha "\$RELEASE_SHA" \\\n\s+--override-reason="\$CI_OVERRIDE_REASON" --output artifacts\/ios-release\/ci-evidence\.json/);
  // Inputs reach shell steps only through env, never through expression text in a script.
  for (const step of job.steps) assert.ok(!step.run?.includes('${{'), `${step.name} interpolates into its script`);
  const archive = job.steps[archiveIndex];
  assert.equal(archive.env.TOASTTY_IOS_VERIFIED_SHA, '${{ steps.ci.outputs.verified_sha }}');
  assert.equal(archive.env.TOASTTY_IOS_SOURCE_SHA, '${{ steps.source.outputs.sha }}');
  assert.equal(archive.env.TOASTTY_IOS_CI_GATE, '${{ steps.ci.outputs.gate }}');
  assert.equal(archive.env.TOASTTY_IOS_UPLOAD,
    "${{ github.ref == 'refs/heads/main' && github.event_name == 'workflow_dispatch' && inputs.upload == true && '1' || '0' }}");
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
});

test('full CI gate blocks every non-success graph result, including abandoned runners', () => {
  for (const name of ['IOS', 'MACOS', 'LINUX', 'SCRIPTS', 'WEB']) {
    for (const result of ['skipped', 'failure', 'cancelled', 'abandoned', '', 'pending']) {
      assert.notEqual(gate({ FULL_RUN: 'true', IOS_RESULT: 'success', MACOS_RESULT: 'success',
        SCRIPTS_RESULT: 'success', WEB_RESULT: 'success', [`${name}_RESULT`]: result }).status, 0);
    }
  }
});
