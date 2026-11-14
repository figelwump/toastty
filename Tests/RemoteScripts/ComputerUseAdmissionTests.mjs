import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = fileURLToPath(new URL("../../", import.meta.url));
const source = readFileSync(join(root, "scripts/remote/computer-use-run.sh"), "utf8");
const quote = (text) => `'${text.replaceAll("'", "'\\''")}'`;
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function until(predicate, description) {
  const deadline = Date.now() + 8000;
  while (!predicate()) {
    assert.ok(Date.now() < deadline, `Timed out: ${description}`);
    await delay(25);
  }
}

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

function fixture(t, mode = "normal") {
  const dir = mkdtempSync(join(tmpdir(), "toastty-cu-session-"));
  const run = join(dir, "runs", "fixture");
  const worktree = join(dir, "worktree");
  mkdirSync(join(worktree, "scripts/dev"), { recursive: true });
  mkdirSync(run, { recursive: true });
  writeFileSync(join(worktree, "scripts/dev/bootstrap-worktree.sh"), "#!/bin/bash\nexit 0\n", { mode: 0o755 });
  const binary = join(dir, "fixture-app");
  writeFileSync(binary, `#!/usr/bin/env python3
import json, os, signal, time
if os.environ.get("FIXTURE_MODE") == "stubborn":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
home = os.environ["TOASTTY_RUNTIME_HOME"]
with open(home + "/instance.json", "w") as output:
    json.dump(dict(pid=os.getpid(), runtimeLabel=os.environ["TOASTTY_RUNTIME_LABEL"], runtimeHomePath=home, socketPath=os.environ["TOASTTY_SOCKET_PATH"]), output)
while True: time.sleep(1)
`, { mode: 0o755 });
  const codex = join(dir, "fixture-codex");
  writeFileSync(codex, "#!/bin/bash\necho fixture-codex\n", { mode: 0o755 });
  // Keep the real prepare/session/stop functions. Replace only native build,
  // LaunchAgent, readiness, and bundle-inspection surfaces with disposable processes.
  const definitions = source.slice(0, source.lastIndexOf("\nwhile [[ $# -gt 0 ]]; do"))
    .replace(/^ROOT_DIR=.*$/m, `ROOT_DIR=${quote(root)}`);
  const script = join(dir, "session.sh");
  writeFileSync(script, definitions + `
CURRENT_CODEX_APP_CLI=${quote(codex)}
REMOTE_RUN_ROOT_ARG=${quote(run)}
REMOTE_WORKTREE_DIR_ARG=${quote(worktree)}
RUN_LABEL=fixture
REMOTE_SESSION=1
TIMEOUT_SECONDS=10
xcodebuild() {
  printf '%s\\n' "$@" >${quote(join(dir, "build-args"))}
  mkdir -p "$(dirname "$app_binary")"
  cp ${quote(binary)} "$app_binary"
}
function /usr/libexec/PlistBuddy() { printf 'com.toastty.fixture\\n'; }
sleep() { /bin/sleep 0.01; }
pick_unused_port() { printf '32123\\n'; }
launchctl() {
  case "$1" in
    bootstrap)
      /bin/sleep 120 </dev/null >/dev/null 2>&1 &
      printf '%s' "$!" >${quote(join(dir, "server-pid"))}
      ;;
    print)
      [[ -f ${quote(join(dir, "server-pid"))} ]] || return 1
      printf 'pid = %s\\n' "$(cat ${quote(join(dir, "server-pid"))})"
      ;;
    bootout)
      if [[ -f ${quote(join(dir, "server-pid"))} ]]; then
        kill "$(cat ${quote(join(dir, "server-pid"))})" || true
        rm ${quote(join(dir, "server-pid"))}
      fi
      ;;
  esac
}
lsof() { [[ -f ${quote(join(dir, "server-pid"))} ]] && cat ${quote(join(dir, "server-pid"))}; }
curl() { [[ "$FIXTURE_MODE" != startup-failure ]]; }
run_remote_prepare_mode
`);
  const marker = join(run, "desktop-active");
  const report = join(run, "admission.json");
  const child = spawn("python3", [join(root, "scripts/remote/admission.py"), "run", "--root", dir,
    "--resource", "desktop", "--label", "fixture", "--timeout", "5", "--runtime-timeout", "15",
    "--release-marker", marker, "--report", report, "--", "/bin/bash", script], {
    env: { ...process.env, PATH: `/usr/bin:/bin:/usr/sbin:/sbin:${process.env.PATH}`, FIXTURE_MODE: mode },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.on("data", (data) => { output += data; });
  child.stderr.on("data", (data) => { output += data; });
  child.stdin.on("error", () => {});
  const completion = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
  const appPID = () => {
    const path = join(run, "runtime-home/instance.json");
    return existsSync(path) ? JSON.parse(readFileSync(path)).pid : null;
  };
  t.after(async () => {
    child.stdin.end();
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
    await completion;
    const pid = appPID();
    if (pid && alive(pid)) process.kill(pid, "SIGKILL");
    rmSync(dir, { recursive: true, force: true });
  });
  return { dir, run, marker, report, child, completion, appPID, output: () => output,
    ready: () => until(() => output.includes("TOASTTY_COMPUTER_USE_READY"), output) };
}

test("Computer Use holds desktop admission until STOP confirms process cleanup", { timeout: 15000 }, async (t) => {
  const f = fixture(t);
  await f.ready();
  assert.equal(existsSync(f.marker), true);
  assert.equal(alive(f.appPID()), true);
  assert.match(readFileSync(join(f.dir, "build-args"), "utf8"), /-jobs\n4\n/);
  const next = join(f.dir, "next-started");
  const competitor = spawn("python3", [join(root, "scripts/remote/admission.py"), "run", "--root", f.dir,
    "--resource", "desktop", "--label", "next", "--timeout", "5", "--", "/bin/bash", "-c", `touch ${quote(next)}`]);
  const competed = new Promise((resolve) => competitor.once("exit", resolve));
  t.after(() => { if (competitor.exitCode === null) competitor.kill("SIGTERM"); });
  await delay(250);
  assert.equal(existsSync(next), false);
  f.child.stdin.end("STOP\n");
  assert.equal((await f.completion).code, 0, f.output());
  assert.equal(existsSync(f.marker), false);
  assert.equal(alive(f.appPID()), false);
  assert.equal(await competed, 0);
  assert.equal(existsSync(next), true);
});

for (const end of ["disconnect", "signal"]) {
  test(`Computer Use ${end} stops owned processes before releasing admission`, { timeout: 15000 }, async (t) => {
    const f = fixture(t);
    await f.ready();
    if (end === "disconnect") f.child.stdin.end();
    else f.child.kill("SIGTERM");
    assert.notEqual((await f.completion).code, 0, f.output());
    assert.equal(existsSync(f.marker), false, f.output());
    assert.equal(alive(f.appPID()), false);
  });
}

test("Computer Use failed app-server startup cleans the app before releasing admission", { timeout: 15000 }, async (t) => {
  const f = fixture(t, "startup-failure");
  f.child.stdin.end();
  assert.notEqual((await f.completion).code, 0, f.output());
  assert.equal(existsSync(f.marker), false, f.output());
  assert.equal(alive(f.appPID()), false);
});

test("Computer Use unconfirmed app cleanup leaves desktop admission blocked", { timeout: 15000 }, async (t) => {
  const f = fixture(t, "stubborn");
  await f.ready();
  f.child.stdin.end("STOP\n");
  assert.notEqual((await f.completion).code, 0, f.output());
  assert.equal(existsSync(f.marker), true);
  assert.match(f.output(), /desktop admission remains reserved/);
  const report = JSON.parse(readFileSync(f.report));
  assert.equal(report.state, "blocked");
});
