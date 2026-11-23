import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const sourceRoot = fileURLToPath(new URL("../../", import.meta.url));
const fixtureHost = "runner-fixture.invalid";
// Bypass Apple's /usr/bin/git launcher, which can probe xcodebuild before it
// starts Git. No build tools are part of these wrapper tests.
const realGit = ["/Applications/Xcode.app/Contents/Developer/usr/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git", "/usr/bin/git"].find(existsSync);
const fixtureExecution = [
  "set -euo pipefail",
  'if [[ -n "${FIXTURE_GATE:-}" ]]; then while [[ ! -e "$FIXTURE_GATE" ]]; do sleep 0.1; done; fi',
  "echo fixture session output",
  'test -f "$3/scripts/remote/run-support.sh"',
  'schema_version=2',
  '[[ "$4" != */scripts/remote/validate.sh ]] || schema_version=1',
  'case "${FIXTURE_RESULT_MODE:-valid}" in',
  `  valid) printf '{"schemaVersion":%s,"status":"pass","executionTarget":"remote","cleanupFailureSummary":null}\\n' "$schema_version" >"$2/result.json" ;;`,
  `  malformed) printf '%s' '{"status":' >"$2/result.json" ;;`,
  `  partial) printf '%s' '{"status":"pass"}' >"$2/result.json" ;;`,
  '  missing) ;;',
  '  *) exit 78 ;;',
  'esac',
  `printf 'remote evidence\\n' >"$2/evidence.log"`,
  `printf '%s' '{"state":"finished"}' >"$2/admission.json"`,
  'case "$4" in',
  '  */scripts/remote/test.sh) : >"$2/COMPLETED" ;;',
  '  */scripts/remote/validate.sh) : >"$2/EXECUTION_FINISHED"; : >"$2/CLEANUP_CONFIRMED" ;;',
  '  *) exit 78 ;;',
  'esac',
  'if [[ "${FIXTURE_UNCONFIRMED_GUI:-0}" == 1 ]]; then',
  '  : >"$2/desktop-active"; : >"$2/CLEANUP_FAILED"',
  `  printf '%s' '{"state":"blocked"}' >"$2/admission.json"`,
  '  exit 78',
  'fi',
].join("\n");
const scripts = [
  "scripts/remote/test.sh",
  "scripts/remote/validate.sh",
  "scripts/remote/run-support.sh", "scripts/remote/admission.py",
  "scripts/remote/live-gateway-test-environment.sh",
  "scripts/remote/ios-simulator-run.sh",
  "scripts/automation/runtime-ownership.sh",
];

function put(path, contents, mode) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, contents, mode === undefined ? undefined : { mode });
}

function succeeds(result) {
  assert.equal(result.error, undefined, String(result.error));
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
}

function git(repo, ...args) {
  const result = spawnSync(realGit, ["-C", repo, ...args], {
    encoding: "utf8",
    env: { PATH: "/usr/bin:/bin:/usr/sbin:/sbin", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null" },
  });
  succeeds(result);
  return result.stdout.trim();
}

function fixture(t, kind) {
  const root = mkdtempSync(join(tmpdir(), "toastty-wrapper-contract-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const repo = join(root, "source");
  const remoteRepo = join(root, "remote-source");
  const remoteRoot = join(root, "remote-runs");
  const bin = join(root, "bin");
  mkdirSync(repo);
  mkdirSync(bin);
  for (const path of scripts) {
    mkdirSync(dirname(join(repo, path)), { recursive: true });
    copyFileSync(join(sourceRoot, path), join(repo, path));
  }
  put(join(repo, ".gitignore"), "artifacts/\n");
  git(repo, "init", "--quiet");
  git(repo, "add", ".");
  git(repo, "-c", "user.name=Runner Test", "-c", "user.email=runner@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Wrapper fixture");
  git(root, "clone", "--quiet", repo, remoteRepo);

  // OpenSSH joins command arguments with spaces before the remote shell parses
  // them. Preserve that behavior, including its quoting rules. Only the remote
  // build/GUI body is replaced; preflight, allocation, and cleanup run unchanged.
  put(join(bin, "ssh"), `#!${process.execPath}
const { readFileSync, appendFileSync } = require("node:fs");
const { spawnSync } = require("node:child_process");
const args = process.argv.slice(2);
let hostIndex = 0;
while (args[hostIndex] === "-o" || args[hostIndex] === "-T") {
  hostIndex += args[hostIndex] === "-o" ? 2 : 1;
}
if (args[hostIndex] !== ${JSON.stringify(fixtureHost)}) throw new Error("Unexpected SSH host");
const script = readFileSync(0, "utf8");
const execution = script.includes('script_path="$4"');
const phase = execution ? "execute" : script.includes("toastty_allocate_remote_run") ? "allocate" : script.includes("worktree remove") ? "cleanup" : "preflight";
appendFileSync(process.env.FIXTURE_TRANSPORT_LOG, phase + "\\n");
if (execution && process.env.FIXTURE_SSH_PID) require("node:fs").writeFileSync(process.env.FIXTURE_SSH_PID, String(process.pid));
const fixtureExecution = ${JSON.stringify(fixtureExecution)};
// Keep command joining faithful while excluding machine-specific login files.
const command = args.slice(hostIndex + 1);
if (command[0] !== "/bin/bash") throw new Error("Unexpected remote shell");
command.splice(1, 0, "--noprofile");
const toolPath = "export PATH=" + ${JSON.stringify(`${dirname(realGit)}:/usr/bin:/bin:/usr/sbin:/sbin`)} + "\\n";
const failRemoval = phase === "cleanup" && process.env.FIXTURE_FAIL_WORKTREE_REMOVAL === "1";
const removalFailure = failRemoval ? [
  'git() {',
  '  local previous="" arg',
  '  for arg in "$@"; do',
  '    if [[ "$previous" == worktree && "$arg" == remove ]]; then',
  '      printf "fixture: Git worktree removal failed\\\\n" >&2',
  '      return 73',
  '    fi',
  '    previous="$arg"',
  '  done',
  '  command git "$@"',
  '}',
].join("\\n") + "\\n" : "";
// With FIXTURE_DETACH, keep the real detach-and-follow launcher and replace
// only the session it runs.
const session = /(<<'TOASTTY_REMOTE_SESSION'\\n)[\\s\\S]*?(\\nTOASTTY_REMOTE_SESSION\\n)/;
const body = !execution ? script : process.env.FIXTURE_DETACH === "1"
  ? script.replace(session, (_, open, close) => open + fixtureExecution + close)
  : fixtureExecution;
const result = spawnSync("/bin/bash", ["-c", command.join(" ")], {
  input: toolPath + removalFailure + body, env: process.env, stdio: ["pipe", "inherit", "inherit"],
});
if (result.error) throw result.error;
process.exit(result.status ?? 1);
`, 0o755);

  // Use the host rsync for both directions. A failed evidence transfer can
  // already have copied result.json and the completion marker before failing.
  put(join(bin, "rsync"), `#!${process.execPath}
const { appendFileSync } = require("node:fs");
const { spawnSync } = require("node:child_process");
const args = process.argv.slice(2);
const prefix = ${JSON.stringify(`${fixtureHost}:`)};
// Local rsync can start its receiver through PATH as an internal server.
if (args.includes("--server")) {
  const receiver = spawnSync("/usr/bin/rsync", args, { stdio: "inherit", env: process.env });
  if (receiver.error) throw receiver.error;
  process.exit(receiver.status ?? 1);
}
const artifactCopy = args[args.length - 2].startsWith(prefix);
const localArgs = [];
for (let index = 0; index < args.length; index += 1) {
  if (args[index] === "-e") { index += 1; continue; }
  localArgs.push(args[index].startsWith(prefix) ? args[index].slice(prefix.length) : args[index]);
}
appendFileSync(process.env.FIXTURE_TRANSPORT_LOG, artifactCopy ? "artifact-copy\\n" : "source-sync\\n");
const result = spawnSync("/usr/bin/rsync", localArgs, { stdio: "inherit", env: process.env });
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);
if (artifactCopy && process.env.FIXTURE_FAIL_ARTIFACT_COPY === "1") {
  process.stderr.write("fixture: artifact transfer failed after partial copy\\n");
  process.exit(23);
}
process.exit(0);
`, 0o755);

  const label = "explicit-run-label";
  const localArtifacts = join(repo, "artifacts", kind === "test" ? "remote-tests" : "remote-gui", label);
  const remoteRun = join(remoteRoot, kind === "test" ? "test-runs" : "runs", label);
  const remoteWorktree = join(remoteRoot, "worktrees", label);
  const transportLog = join(root, "transport.log");
  const env = {
    PATH: `${bin}:${dirname(realGit)}:/usr/bin:/bin:/usr/sbin:/sbin:${dirname(process.execPath)}`,
    TMPDIR: root,
    ARCH: "arm64",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: "/dev/null",
    TOASTTY_REMOTE_GUI_HOST: fixtureHost,
    TOASTTY_REMOTE_GUI_REPO_ROOT: remoteRepo,
    TOASTTY_REMOTE_GUI_ROOT: remoteRoot,
    FIXTURE_TRANSPORT_LOG: transportLog,
  };
  function run(extraEnv = {}) {
    const args = [join(repo, `scripts/remote/${kind}.sh`), "--scope", "working-tree", "--run-label", label];
    if (kind === "validate") args.push("--validation-command", "true");
    return spawnSync("/bin/bash", args, { cwd: repo, env: { ...env, ...extraEnv }, encoding: "utf8", timeout: 30_000 });
  }
  function start(extraEnv = {}) {
    const args = [join(repo, `scripts/remote/${kind}.sh`), "--scope", "working-tree", "--run-label", label];
    if (kind === "validate") args.push("--validation-command", "true");
    const child = spawn("/bin/bash", args, { cwd: repo, env: { ...env, ...extraEnv }, detached: true, stdio: "ignore" });
    child.finished = new Promise((resolve) => child.on("exit", resolve));
    return child;
  }
  function phases() { return readFileSync(transportLog, "utf8").trim().split("\n"); }
  function metadata() { return JSON.parse(readFileSync(join(localArtifacts, "run-metadata.json"), "utf8")); }
  return { run, start, phases, metadata, localArtifacts, remoteRun, remoteWorktree, remoteRepo, repo, root };
}

for (const kind of ["test", "validate"]) {
  test(`${kind}.sh preserves blocked admission and its marker even when a pass result exists`, (t) => {
    const context = fixture(t, kind);
    const result = context.run({ FIXTURE_UNCONFIRMED_GUI: "1" });
    assert.notEqual(result.status, 0);
    assert.ok(existsSync(join(context.remoteRun, "desktop-active")));
    assert.ok(existsSync(context.remoteWorktree));
    assert.equal(context.metadata().remoteRemoved, false);
    assert.equal(JSON.parse(readFileSync(join(context.localArtifacts, "result.json"), "utf8")).status, "fail");
    assert.ok(!context.phases().includes("cleanup"));
  });
  test(`${kind}.sh retains remote evidence and fails when copying a pass result fails`, (t) => {
    const context = fixture(t, kind);
    const result = context.run({ FIXTURE_FAIL_ARTIFACT_COPY: "1" });
    assert.equal(result.error, undefined, String(result.error));
    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stderr, /artifact transfer failed after partial copy/);
    assert.equal(JSON.parse(readFileSync(join(context.remoteRun, "result.json"), "utf8")).status, "pass");
    assert.equal(JSON.parse(readFileSync(join(context.localArtifacts, "result.json"), "utf8")).status, "fail");
    assert.equal(readFileSync(join(context.remoteRun, "evidence.log"), "utf8"), "remote evidence\n");
    assert.equal(git(context.remoteWorktree, "rev-parse", "--is-inside-work-tree"), "true");
    assert.deepEqual(context.phases(), ["preflight", "allocate", "source-sync", "source-sync", "execute", "artifact-copy"]);
    const metadata = context.metadata();
    assert.equal(metadata.status, "fail");
    assert.notEqual(metadata.exitCode, 0);
    assert.equal(metadata.remoteRemoved, false);
    assert.equal(metadata.remoteRunRoot, context.remoteRun);
    assert.equal(metadata.remoteWorktree, context.remoteWorktree);
  });

  for (const collision of ["run", "worktree"]) {
    test(`${kind}.sh rejects an occupied remote ${collision} label without changing existing evidence`, (t) => {
      const context = fixture(t, kind);
      // An existing worktree is registered with Git and has untracked evidence.
      git(context.remoteRepo, "worktree", "add", "--detach", context.remoteWorktree);
      put(join(context.remoteWorktree, "sentinel.log"), "worktree from the earlier run\n");
      if (collision === "run") {
        put(join(context.remoteRun, "result.json"), '{"status":"pass","earlierRun":true}\n');
        put(join(context.remoteRun, "COMPLETED"), "earlier completion\n");
      }
      const registrations = git(context.remoteRepo, "worktree", "list", "--porcelain");
      const result = context.run();
      assert.equal(result.error, undefined, String(result.error));
      assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
      assert.match(result.stderr, /already exists or cannot be created/);
      assert.equal(readFileSync(join(context.remoteWorktree, "sentinel.log"), "utf8"), "worktree from the earlier run\n");
      assert.equal(git(context.remoteRepo, "worktree", "list", "--porcelain"), registrations);
      if (collision === "run") {
        assert.equal(readFileSync(join(context.remoteRun, "result.json"), "utf8"), '{"status":"pass","earlierRun":true}\n');
        assert.equal(readFileSync(join(context.remoteRun, "COMPLETED"), "utf8"), "earlier completion\n");
      } else {
        assert.equal(existsSync(context.remoteRun), false);
      }
      assert.deepEqual(context.phases(), ["preflight", "allocate"]);
      assert.equal(context.metadata().status, "fail");
    });
  }

  test(`${kind}.sh copies successful evidence before removing its remote worktree and run`, (t) => {
    const context = fixture(t, kind);
    succeeds(context.run());
    assert.equal(JSON.parse(readFileSync(join(context.localArtifacts, "result.json"), "utf8")).status, "pass");
    const copiedArtifacts = kind === "test" ? context.localArtifacts : join(context.localArtifacts, "remote");
    assert.equal(readFileSync(join(copiedArtifacts, "evidence.log"), "utf8"), "remote evidence\n");
    assert.equal(existsSync(context.remoteRun), false);
    assert.equal(existsSync(context.remoteWorktree), false);
    assert.equal(git(context.remoteRepo, "worktree", "list", "--porcelain").includes(context.remoteWorktree), false);
    assert.deepEqual(context.phases(), ["preflight", "allocate", "source-sync", "source-sync", "execute", "artifact-copy", "cleanup"]);
    assert.equal(context.metadata().status, "pass");
    assert.equal(context.metadata().remoteRemoved, true);
  });

  test(`${kind}.sh reports cleanup failure and retains evidence when Git cannot remove its worktree`, (t) => {
    const context = fixture(t, kind);
    const result = context.run({ FIXTURE_FAIL_WORKTREE_REMOVAL: "1" });
    assert.equal(result.error, undefined, String(result.error));
    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stderr, /Git worktree removal failed/);
    assert.equal(JSON.parse(readFileSync(join(context.localArtifacts, "result.json"), "utf8")).status, "fail");
    assert.equal(JSON.parse(readFileSync(join(context.remoteRun, "result.json"), "utf8")).status, "pass");
    assert.equal(readFileSync(join(context.remoteRun, "evidence.log"), "utf8"), "remote evidence\n");
    assert.equal(git(context.remoteWorktree, "rev-parse", "--is-inside-work-tree"), "true");
    assert.equal(git(context.remoteRepo, "worktree", "list", "--porcelain").includes(context.remoteWorktree), true);
    assert.deepEqual(context.phases(), ["preflight", "allocate", "source-sync", "source-sync", "execute", "artifact-copy", "cleanup"]);
    assert.equal(context.metadata().status, "fail");
    assert.equal(context.metadata().remoteRemoved, false);
  });
}

for (const [mode, rawResult] of [["malformed", '{"status":'], ["partial", '{"status":"pass"}']]) {
  test(`validate.sh retains raw evidence and fails when result.json is ${mode}`, (t) => {
    const context = fixture(t, "validate");
    const result = context.run({ FIXTURE_RESULT_MODE: mode });
    assert.equal(result.error, undefined, String(result.error));
    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.equal(JSON.parse(readFileSync(join(context.localArtifacts, "result.json"), "utf8")).status, "fail");
    assert.equal(readFileSync(join(context.localArtifacts, "remote/result.json"), "utf8"), rawResult);
    assert.equal(readFileSync(join(context.remoteRun, "result.json"), "utf8"), rawResult);
    assert.equal(readFileSync(join(context.remoteRun, "evidence.log"), "utf8"), "remote evidence\n");
    assert.equal(git(context.remoteWorktree, "rev-parse", "--is-inside-work-tree"), "true");
    assert.deepEqual(context.phases(), ["preflight", "allocate", "source-sync", "source-sync", "execute", "artifact-copy"]);
    assert.equal(context.metadata().status, "fail");
    assert.equal(context.metadata().remoteRemoved, false);
  });
}

test("test.sh cannot authorize remote removal from COMPLETED and a synthesized missing result", (t) => {
  const context = fixture(t, "test");
  const result = context.run({ FIXTURE_RESULT_MODE: "missing" });
  assert.equal(result.error, undefined, String(result.error));
  assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.equal(JSON.parse(readFileSync(join(context.localArtifacts, "result.json"), "utf8")).status, "fail");
  assert.equal(existsSync(join(context.localArtifacts, "COMPLETED")), true);
  assert.equal(existsSync(join(context.remoteRun, "COMPLETED")), true);
  assert.equal(existsSync(join(context.remoteRun, "result.json")), false);
  assert.equal(readFileSync(join(context.remoteRun, "evidence.log"), "utf8"), "remote evidence\n");
  assert.equal(git(context.remoteWorktree, "rev-parse", "--is-inside-work-tree"), "true");
  assert.deepEqual(context.phases(), ["preflight", "allocate", "source-sync", "source-sync", "execute", "artifact-copy"]);
  assert.equal(context.metadata().status, "fail");
  assert.equal(context.metadata().remoteRemoved, false);
});

async function until(check, ms = 15000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (check()) return;
    await new Promise((r) => setTimeout(r, 50));
  }
  assert.fail("condition not reached");
}

for (const kind of ["test", "validate"]) {
  test(`${kind}.sh keeps a remote run going after its wrapper stops, and the same command reattaches`, { timeout: 60000 }, async (t) => {
    const context = fixture(t, kind);
    const gate = join(context.root, "gate");
    const detach = { FIXTURE_DETACH: "1", FIXTURE_GATE: gate };
    const first = context.start(detach);
    await until(() => existsSync(join(context.remoteRun, "detached.json")));
    // Toastty quitting sends TERM to the wrapper and its SSH session.
    process.kill(-first.pid, "SIGTERM");
    await first.finished;
    assert.equal(existsSync(join(context.localArtifacts, "result.json")), false);
    assert.equal(existsSync(join(context.localArtifacts, "attach.env")), true);
    assert.equal(existsSync(join(context.remoteRun, "detached-exit.json")), false);
    writeFileSync(gate, "");
    await until(() => existsSync(join(context.remoteRun, "detached-exit.json")));
    const second = context.run(detach);
    succeeds(second);
    assert.match(second.stdout + second.stderr, /Reattaching to remote run explicit-run-label/);
    assert.equal(JSON.parse(readFileSync(join(context.localArtifacts, "result.json"), "utf8")).status, "pass");
    assert.match(readFileSync(join(context.localArtifacts, "remote-stdout.log"), "utf8"), /fixture session output/);
    assert.equal(existsSync(context.remoteRun), false);
    assert.equal(context.metadata().remoteRemoved, true);
  });

  test(`${kind}.sh does not reattach to a stopped run after the source changed`, { timeout: 60000 }, async (t) => {
    const context = fixture(t, kind);
    const gate = join(context.root, "gate");
    const first = context.start({ FIXTURE_DETACH: "1", FIXTURE_GATE: gate });
    await until(() => existsSync(join(context.remoteRun, "detached.json")));
    process.kill(-first.pid, "SIGTERM");
    await first.finished;
    put(join(context.repo, "changed.txt"), "new source\n");
    const second = context.run({ FIXTURE_DETACH: "1", FIXTURE_GATE: gate });
    assert.notEqual(second.status, 0);
    assert.doesNotMatch(second.stdout + second.stderr, /Reattaching/);
    assert.match(second.stderr, /already exists/);
    // Let the earlier detached run end so that no process outlives the test.
    writeFileSync(gate, "");
    await until(() => existsSync(join(context.remoteRun, "detached-exit.json")));
  });
}

for (const kind of ["test", "validate"]) {
  test(`${kind}.sh stops without a result when only its connection drops, and a rerun reattaches`, { timeout: 90000 }, async (t) => {
    const context = fixture(t, kind);
    const gate = join(context.root, "gate"), sshPid = join(context.root, "ssh.pid");
    const first = context.start({ FIXTURE_DETACH: "1", FIXTURE_GATE: gate, FIXTURE_SSH_PID: sshPid });
    await until(() => existsSync(join(context.remoteRun, "detached.json")) && existsSync(sshPid));
    process.kill(Number(readFileSync(sshPid, "utf8")), "SIGKILL");
    assert.notEqual(await first.finished, 0);
    assert.equal(existsSync(join(context.localArtifacts, "result.json")), false);
    assert.equal(existsSync(join(context.remoteRun, "detached-exit.json")), false);
    writeFileSync(gate, "");
    const second = context.run({ FIXTURE_DETACH: "1", FIXTURE_GATE: gate });
    succeeds(second);
    assert.match(second.stdout + second.stderr, /Reattaching to remote run explicit-run-label/);
    assert.equal(JSON.parse(readFileSync(join(context.localArtifacts, "result.json"), "utf8")).status, "pass");
    assert.equal(existsSync(context.remoteRun), false);
  });
}
