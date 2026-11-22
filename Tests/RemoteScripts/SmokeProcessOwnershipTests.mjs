import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const source = fileURLToPath(new URL("../../", import.meta.url));
function alive(pid) {
  try { process.kill(pid, 0); return true; } catch (error) {
    if (error.code === "ESRCH") return false;
    throw error;
  }
}

for (const script of ["workspace-scope-smoke.sh", "smoke-cli-live-control.sh"]) {
  test(`${script} stops its actual app when a smoke assertion fails`, async (t) => {
    const root = mkdtempSync(join(tmpdir(), "tt-so-"));
    const repo = join(root, "repo"), bin = join(root, "bin"), run = join(root, "run");
    const pidFile = join(root, "app-pid"), reached = join(root, "cli-reached");
    let pid;
    t.after(async () => {
      if (pid && alive(pid)) process.kill(pid, "SIGTERM");
      for (let n = 0; pid && alive(pid) && n < 100; n++) await new Promise((resolve) => setTimeout(resolve, 20));
      assert.ok(!pid || !alive(pid), "owned fixture app must exit before its files are removed");
      rmSync(root, { recursive: true, force: true });
    });
    function put(path, text) {
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, text, { mode: 0o755 });
    }
    for (const path of [`scripts/automation/${script}`, "scripts/automation/runtime-ownership.sh"]) {
      mkdirSync(dirname(join(repo, path)), { recursive: true });
      copyFileSync(join(source, path), join(repo, path));
    }
    put(join(repo, "scripts/dev/bootstrap-worktree.sh"), "#!/bin/bash\nexit 0\n");
    put(join(bin, "xcodebuild"), "#!/bin/bash\nexit 0\n");
    put(join(bin, "lsappinfo"), "#!/bin/bash\nexit 1\n");
    const products = join(run, "Derived/Build/Products/Debug");
    // Real child process and Unix socket, with native build/GUI tools replaced.
    put(join(products, "Toastty.app/Contents/MacOS/Toastty"), `#!${process.execPath}
const fs = require("node:fs"), net = require("node:net"), path = require("node:path");
fs.writeFileSync(process.env.FIXTURE_PID_FILE, String(process.pid));
const socket = process.env.FIXTURE_SOCKET;
net.createServer().listen(socket, () => fs.writeFileSync(path.join(process.env.TOASTTY_RUNTIME_HOME, "instance.json"), JSON.stringify({
  pid: process.pid, runtimeLabel: process.env.TOASTTY_RUNTIME_LABEL,
  runtimeHomePath: fs.realpathSync(process.env.TOASTTY_RUNTIME_HOME), socketPath: socket
})));
`);
    put(join(products, "toastty"), `#!${process.execPath}
require("node:fs").writeFileSync(process.env.FIXTURE_REACHED, "yes");
if (process.argv.includes("action") && process.argv.includes("list")) console.log('{"ok":true,"result":{"actions":[]}}');
else process.exit(23);
`);
    const result = spawnSync("/bin/bash", [join(repo, `scripts/automation/${script}`)], {
      cwd: repo, encoding: "utf8", timeout: 20_000,
      env: { ...process.env, PATH: `${bin}:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`,
        RUN_ID: "launch-fixture", DEV_RUN_ROOT: run, DERIVED_PATH: join(run, "Derived"),
        ARTIFACTS_DIR: join(run, "artifacts"), TOASTTY_RUNTIME_HOME: join(run, "runtime-home"),
        TOASTTY_WORKSPACE_SCOPE_RESTORE_FRONT_APP: "0", TOASTTY_CLI_LIVE_RESTORE_FRONT_APP: "0",
        FIXTURE_PID_FILE: pidFile, FIXTURE_REACHED: reached, FIXTURE_SOCKET: join(root, "s"), ARCH: "arm64" },
    });
    if (existsSync(pidFile)) pid = Number(readFileSync(pidFile, "utf8"));
    assert.equal(result.error, undefined, String(result.error));
    assert.ok(pid && existsSync(reached), `fixture must reach the real smoke CLI after app launch: ${result.stdout}\n${result.stderr}`);
    assert.notEqual(result.status, 0, "the deliberate smoke assertion must fail");
    assert.equal(alive(pid), false, "smoke cleanup must stop the actual app, not only its launching shell");
  });
}
