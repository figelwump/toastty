import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

// Real processes and flock leases, with no Xcode, app, SSH or provider calls.
const helper = fileURLToPath(new URL("../../scripts/remote/admission.py", import.meta.url));
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "toastty-admission-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}
function status(root) {
  const p = spawnSync("python3", [helper, "status", "--root", root], { encoding: "utf8" });
  assert.equal(p.status, 0, p.stderr);
  return JSON.parse(p.stdout);
}
function run(root, label, resource, options = [], command = ["python3", "-c", "import time; time.sleep(30)"]) {
  const child = spawn("python3", [helper, "run", "--root", root, "--label", label, "--resource", resource, "--timeout", "8", ...options, "--", ...command]);
  let stderr = "";
  child.stderr.on("data", (d) => { stderr += d; });
  child.finished = new Promise((resolve) => child.on("exit", (code, signal) => resolve({ code, signal, stderr })));
  return child;
}
async function until(check) {
  const end = Date.now() + 7000;
  while (Date.now() < end) {
    if (check()) return;
    await new Promise((r) => setTimeout(r, 40));
  }
  assert.fail("Admission state did not reach the expected condition");
}
async function stop(child) { child.kill("SIGTERM"); await child.finished; }

test("status is read-only, including before the first request", (t) => {
  const root = fixture(t);
  assert.deepEqual(status(root).running, []);
  assert.equal(existsSync(join(root, ".admission")), false);
});

test("status reports first-writer initialization without creating its lock", (t) => {
  const root = fixture(t);
  mkdirSync(join(root, ".admission"));
  assert.equal(status(root).initializing, true);
  assert.equal(existsSync(join(root, ".admission", "state.lock")), false);
});

test("two compute workers overlap; a third waits and records actual queue time", async (t) => {
  const root = fixture(t);
  const a = run(root, "compute-a", "compute"), b = run(root, "compute-b", "compute");
  t.after(async () => { await stop(a); await stop(b); });
  await until(() => status(root).running.length === 2);
  const report = join(root, "third-report.json");
  const c = run(root, "compute-c", "compute", ["--report", report], ["python3", "-c", "print('done')"]);
  await until(() => status(root).waiting.length === 1);
  await stop(a);
  assert.equal((await c.finished).code, 0);
  const evidence = JSON.parse(readFileSync(report, "utf8"));
  assert.equal(evidence.resource, "compute");
  assert.ok(evidence.queueSeconds > 0);
  assert.equal(evidence.exitCode, 0);
});

test("desktop ownership is exclusive without blocking an eligible compute worker", async (t) => {
  const root = fixture(t);
  const a = run(root, "desktop-a", "desktop");
  await until(() => status(root).running.length === 1);
  const b = run(root, "desktop-b", "desktop");
  await until(() => status(root).waiting.length === 1);
  const c = run(root, "compute", "compute");
  t.after(async () => { await stop(a); await stop(b); await stop(c); });
  await until(() => status(root).running.length === 2);
  assert.deepEqual(status(root).running.map((x) => x.label).sort(), ["compute", "desktop-a"]);
  await stop(a);
  await until(() => status(root).running.some((x) => x.label === "desktop-b"));
});

test("queue timeout and cancellation never start the waiting command", async (t) => {
  const root = fixture(t);
  const a = run(root, "desktop-owner", "desktop");
  t.after(() => stop(a));
  await until(() => status(root).running.length === 1);
  const sentinel = join(root, "must-not-run");
  const command = ["python3", "-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).touch()", sentinel];
  const b = run(root, "timeout", "desktop", ["--timeout", "0.2"], command);
  assert.equal((await b.finished).code, 75);
  assert.equal(existsSync(sentinel), false);
  const c = run(root, "cancelled", "desktop", [], command);
  await until(() => status(root).waiting.some((x) => x.label === "cancelled"));
  await stop(c);
  assert.equal(existsSync(sentinel), false);
  assert.equal(status(root).waiting.length, 0);
});

test("a surviving command retains its lease after the supervisor is killed", async (t) => {
  const root = fixture(t), pidPath = join(root, "child.pid");
  const a = run(root, "survivor", "desktop", [], ["python3", "-c", "import os,pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)", pidPath]);
  await until(() => existsSync(pidPath));
  const pid = Number(readFileSync(pidPath, "utf8"));
  t.after(() => { try { process.kill(pid, "SIGKILL"); } catch {} });
  a.kill("SIGKILL"); await a.finished;
  assert.equal(status(root).running.length, 1);
  const b = run(root, "cannot-overlap", "desktop", ["--timeout", "0.2"], ["true"]);
  assert.equal((await b.finished).code, 75);
  process.kill(pid, "SIGKILL");
  await until(() => status(root).running.length === 0);
});

test("unconfirmed GUI cleanup blocks desktop reuse until the owner's marker is removed", async (t) => {
  const root = fixture(t), marker = join(root, "desktop-active");
  const a = run(root, "unclean", "desktop", ["--release-marker", marker], ["python3", "-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).touch()", marker]);
  assert.notEqual((await a.finished).code, 0);
  assert.equal(status(root).blocked.length, 1);
  const b = run(root, "blocked", "desktop", ["--timeout", "0.2"], ["true"]);
  assert.equal((await b.finished).code, 75);
  rmSync(marker);
  const c = run(root, "clean-again", "desktop", [], ["true"]);
  assert.equal((await c.finished).code, 0);
});

test("a child lease is not hidden when its direct wrapper exits on TERM", async (t) => {
  const root = fixture(t), childPid = join(root, "grandchild.pid");
  const leaf = "import os,pathlib,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)";
  const wrapper = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2]],close_fds=False); time.sleep(30)";
  const a = run(root, "wrapper", "desktop", [], ["python3", "-c", wrapper, leaf, childPid]);
  await until(() => existsSync(childPid));
  const pid = Number(readFileSync(childPid, "utf8"));
  t.after(() => { try { process.kill(pid, "SIGKILL"); } catch {} });
  await stop(a);
  assert.equal(status(root).running.length, 1);
  const b = run(root, "still-owned", "desktop", ["--timeout", "0.2"], ["true"]);
  assert.equal((await b.finished).code, 75);
  process.kill(pid, "SIGKILL");
  await until(() => status(root).running.length === 0);
});

test("runtime timeout stops the owned command and reports failure", async (t) => {
  const root = fixture(t), report = join(root, "report.json");
  const a = run(root, "runtime-timeout", "compute", ["--runtime-timeout", "0.2", "--report", report]);
  assert.equal((await a.finished).code, 124);
  assert.equal(JSON.parse(readFileSync(report, "utf8")).exitCode, 124);
  assert.equal(status(root).running.length, 0);
});

test("invalid state and out-of-root marker paths fail before a command runs", async (t) => {
  const root = fixture(t), sentinel = join(root, "sentinel");
  const a = run(root, "outside", "desktop", ["--release-marker", join(root, "..", "outside")], ["touch", sentinel]);
  assert.notEqual((await a.finished).code, 0);
  assert.equal(existsSync(sentinel), false);
  // Corrupt live metadata cannot silently turn an active desktop into idle.
  const b = run(root, "owner", "desktop"); t.after(() => stop(b));
  await until(() => status(root).running.length === 1);
  const request = status(root).running[0];
  writeFileSync(join(root, ".admission", "requests", `${request.id}.json`), "{");
  const c = run(root, "corrupt", "desktop", [], ["touch", sentinel]);
  assert.notEqual((await c.finished).code, 0);
  assert.equal(existsSync(sentinel), false);
});
