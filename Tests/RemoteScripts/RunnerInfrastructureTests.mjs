import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const helper = fileURLToPath(new URL("../../scripts/remote/run-support.sh", import.meta.url));
const sourceRoot = fileURLToPath(new URL("../../", import.meta.url));

function isolatedEnvironment(root) {
  return { PATH: `/usr/bin:/bin:/usr/sbin:/sbin:${dirname(process.execPath)}`, HOME: root, TMPDIR: root };
}

function wrapperRepository(root) {
  const repo = repository(root);
  for (const path of ["scripts/remote/test.sh", "scripts/remote/validate.sh", "scripts/remote/computer-use-run.sh", "scripts/remote/run-support.sh", "scripts/remote/live-gateway-test-environment.sh", "scripts/remote/ios-simulator-run.sh", "scripts/automation/runtime-ownership.sh"]) {
    mkdirSync(dirname(join(repo, path)), { recursive: true });
    copyFileSync(join(sourceRoot, path), join(repo, path));
  }
  put(repo, ".gitignore", "artifacts/\n");
  git(repo, "add", ".");
  git(repo, "-c", "user.name=Runner Test", "-c", "user.email=runner@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Runner fixture");
  return repo;
}

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "toastty-runner-contract-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

function invoke(name, ...args) {
  return spawnSync("/bin/bash", ["-c", 'set -euo pipefail; source "$1"; shift; "$@"', "runner-test", helper, name, ...args], { encoding: "utf8" });
}

function invokeAsync(name, ...args) {
  return new Promise((resolve, reject) => {
    const child = spawn("/bin/bash", ["-c", 'set -euo pipefail; source "$1"; shift; "$@"', "runner-test", helper, name, ...args]);
    let stderr = "";
    child.stderr.on("data", (data) => { stderr += data; });
    child.on("error", reject);
    child.on("close", (status) => resolve({ status, stderr }));
  });
}

function succeeds(result) {
  assert.equal(result.status, 0, result.stderr);
}

function git(repo, ...args) {
  const result = spawnSync("git", ["-C", repo, ...args], { encoding: "utf8" });
  succeeds(result);
  return result.stdout.trim();
}

function repository(root) {
  const repo = join(root, "repo");
  mkdirSync(repo);
  git(repo, "init", "--quiet");
  git(repo, "-c", "user.name=Runner Test", "-c", "user.email=runner@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", "Fixture");
  return repo;
}

function put(root, path, contents = path) {
  mkdirSync(dirname(join(root, path)), { recursive: true });
  writeFileSync(join(root, path), contents);
}

test("default labels are valid and unique for rapid consecutive calls", () => {
  const labels = Array.from({ length: 24 }, () => {
    const result = invoke("toastty_default_run_label", "test");
    succeeds(result);
    const label = result.stdout.trim();
    assert.match(label, /^test-.+/);
    succeeds(invoke("toastty_validate_run_label", label));
    return label;
  });
  assert.equal(new Set(labels).size, labels.length);
});

test("labels reject path escapes and shell-sensitive or empty values", () => {
  for (const label of ["", ".", "..", "../outside", "a/b", "/absolute", "a b", "a\nb", "a;echo", "-option", "a".repeat(129)]) {
    assert.notEqual(invoke("toastty_validate_run_label", label).status, 0, JSON.stringify(label));
  }
  for (const label of ["run-123", "a.b_c", "a".repeat(128)]) {
    succeeds(invoke("toastty_validate_run_label", label));
  }
});

test("local allocation refuses stale evidence and dangling symlinks unchanged", (t) => {
  const root = fixture(t);
  const artifacts = join(root, "artifacts", "run");
  succeeds(invoke("toastty_allocate_local_artifacts", artifacts));
  put(artifacts, "result.json", '{"status":"pass"}');
  put(artifacts, "COMPLETED", "old completion");
  assert.notEqual(invoke("toastty_allocate_local_artifacts", artifacts).status, 0);
  assert.equal(readFileSync(join(artifacts, "result.json"), "utf8"), '{"status":"pass"}');
  assert.equal(readFileSync(join(artifacts, "COMPLETED"), "utf8"), "old completion");
  const link = join(root, "dangling");
  symlinkSync(join(root, "missing"), link);
  assert.notEqual(invoke("toastty_allocate_local_artifacts", link).status, 0);
  assert.equal(readlinkSync(link), join(root, "missing"));
});

test("concurrent local allocation has exactly one winner", async (t) => {
  const destination = join(fixture(t), "artifacts", "shared");
  const results = await Promise.all(Array.from({ length: 8 }, () => invokeAsync("toastty_allocate_local_artifacts", destination)));
  assert.equal(results.filter(({ status }) => status === 0).length, 1, JSON.stringify(results));
  assert.ok(lstatSync(destination).isDirectory());
});

test("concurrent remote allocation preserves a single detached worktree", async (t) => {
  const root = fixture(t);
  const repo = repository(root);
  const worktree = join(root, "worktrees", "shared");
  const run = join(root, "runs", "shared");
  const results = await Promise.all(Array.from({ length: 6 }, () => invokeAsync("toastty_allocate_remote_run", repo, worktree, run)));
  assert.equal(results.filter(({ status }) => status === 0).length, 1, JSON.stringify(results));
  assert.equal(git(worktree, "rev-parse", "HEAD"), git(repo, "rev-parse", "HEAD"));
  assert.equal(git(worktree, "rev-parse", "--abbrev-ref", "HEAD"), "HEAD");
  assert.ok(lstatSync(run).isDirectory());
});

test("separate run roots cannot claim the same worktree", async (t) => {
  const root = fixture(t);
  const repo = repository(root);
  const worktree = join(root, "worktrees", "shared");
  const results = await Promise.all(["runs", "test-runs"].map((category) =>
    invokeAsync("toastty_allocate_remote_run", repo, worktree, join(root, category, "shared"))));
  assert.equal(results.filter(({ status }) => status === 0).length, 1, JSON.stringify(results));
  assert.equal(git(worktree, "rev-parse", "HEAD"), git(repo, "rev-parse", "HEAD"));
});

test("remote allocation leaves existing paths and dangling links unchanged", (t) => {
  const root = fixture(t);
  const repo = repository(root);
  for (const occupiedPath of ["run", "worktree"]) {
    for (const kind of ["directory", "symlink"]) {
      const base = join(root, `${occupiedPath}-${kind}`);
      const run = join(base, "run");
      const worktree = join(base, "worktree");
      const occupied = occupiedPath === "run" ? run : worktree;
      mkdirSync(base);
      if (kind === "directory") put(occupied, "evidence", "preserve me");
      else symlinkSync(join(base, "absent"), occupied);
      assert.notEqual(invoke("toastty_allocate_remote_run", repo, worktree, run).status, 0);
      if (kind === "directory") assert.equal(readFileSync(join(occupied, "evidence"), "utf8"), "preserve me");
      else assert.equal(readlinkSync(occupied), join(base, "absent"));
    }
  }
});

test("failed git allocation preserves a stale worktree registration", (t) => {
  const root = fixture(t);
  const repo = repository(root);
  const worktree = join(root, "worktrees", "registered");
  const run = join(root, "runs", "registered");
  git(repo, "worktree", "add", "--detach", worktree);
  rmSync(worktree, { recursive: true });
  const before = git(repo, "worktree", "list", "--porcelain");
  assert.notEqual(invoke("toastty_allocate_remote_run", repo, worktree, run).status, 0);
  assert.equal(git(repo, "worktree", "list", "--porcelain"), before);
  assert.equal(existsSync(worktree), false);
  assert.equal(existsSync(run), false);
});

test("default copies retain evidence and nested xcresult bundles while full copies retain products", (t) => {
  const root = fixture(t);
  const source = join(root, "source");
  const evidence = ["result.json", "request.env", "COMPLETED", "app.log", "screenshots/window.png", "recordings/run.mov", "Results.xcresult/Data/data", "nested/Test.xcresult/Info.plist", "Derived/Logs/Test/log.txt", "Derived/Logs/Test/Nested.xcresult/Data/data", "Derived/Build/Results.xcresult/Data/data"];
  const products = ["Derived/Build/Products/Debug/Toastty.app/Contents/MacOS/Toastty", "Derived/ModuleCache.noindex/module.pcm", "Derived/Index.noindex/store/data"];
  for (const path of [...evidence, ...products]) put(source, path);
  for (const full of ["0", "1"]) {
    const destination = join(root, `copy-${full}`);
    mkdirSync(destination);
    succeeds(invoke("toastty_copy_run_artifacts", `${source}/`, `${destination}/`, full));
    for (const path of evidence) assert.equal(readFileSync(join(destination, path), "utf8"), path);
    for (const path of products) assert.equal(existsSync(join(destination, path)), full === "1", path);
  }
});

for (const { script, category, args } of [
  { script: "validate.sh", category: "remote-gui", args: ["--require-remote", "--smoke-test", "smoke-ui"] },
  { script: "test.sh", category: "remote-tests", args: [] },
  { script: "computer-use-run.sh", category: "remote-gui", args: [] },
]) {
  test(`${script} records missing-host failure and refuses to overwrite an explicit label`, (t) => {
    const root = fixture(t);
    const repo = wrapperRepository(root);
    const label = "entry-point-fixture";
    const artifacts = join(repo, "artifacts", category, label);
    const run = () => spawnSync("/bin/bash", [join(repo, "scripts/remote", script), "--run-label", label, ...args], {
      cwd: repo, env: isolatedEnvironment(root), encoding: "utf8",
    });
    const first = run();
    assert.notEqual(first.status, 0);
    assert.match(first.stderr, /TOASTTY_REMOTE_GUI_HOST/);
    const metadata = JSON.parse(readFileSync(join(artifacts, "run-metadata.json"), "utf8"));
    assert.equal(metadata.runLabel, label);
    assert.equal(metadata.exitCode, first.status);
    assert.equal(metadata.status, "fail");
    assert.equal(metadata.lastPhase, "setup");
    assert.equal(metadata.source.commit, git(repo, "rev-parse", "HEAD"));
    assert.equal(metadata.source.dirty, false);
    assert.ok(metadata.phaseSeconds.setup >= 0);
    assert.equal(metadata.remoteRemoved, false);
    // The Computer Use wrapper fails before writing result.json. Seed one so
    // every entry point must preserve both result and metadata on collision.
    if (!existsSync(join(artifacts, "result.json"))) put(artifacts, "result.json", '{"status":"old-result"}');
    put(artifacts, "sentinel", "original evidence");
    const preserved = ["run-metadata.json", "result.json", "sentinel"].map((path) => [path, readFileSync(join(artifacts, path), "utf8")]);
    const duplicate = run();
    assert.notEqual(duplicate.status, 0);
    assert.match(duplicate.stderr, /already exists|new run label/);
    for (const [path, contents] of preserved) assert.equal(readFileSync(join(artifacts, path), "utf8"), contents, path);
  });
}

test("metadata identifies selected source and accounts for failure phases without command or prompt contents", (t) => {
  const root = fixture(t);
  const repo = repository(root);
  const previousCommit = git(repo, "rev-parse", "HEAD");
  put(repo, "tracked.txt", "committed source");
  git(repo, "add", "tracked.txt");
  git(repo, "-c", "user.name=Runner Test", "-c", "user.email=runner@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Source update");
  const currentCommit = git(repo, "rev-parse", "HEAD");
  put(repo, "tracked.txt", "uncommitted source");
  const sensitiveText = "fixture-private-input-not-for-metadata";
  for (const scope of ["head", "ref", "working-tree"]) {
    const artifacts = join(root, `metadata-${scope}`);
    mkdirSync(artifacts);
    const result = spawnSync("/bin/bash", ["-c", `
set -euo pipefail
source "$1"
ROOT_DIR="$2" LOCAL_ARTIFACTS_DIR="$3" RUN_LABEL="metadata-fixture"
VALIDATION_SCOPE="$4" REF_SPEC="$5" FULL_ARTIFACTS=0
PROMPT_TEXT="$6" VALIDATION_COMMAND="$6"
toastty_begin_run_metadata validation macos custom-command
toastty_run_phase synchronization
toastty_run_phase execution
exit 23
`, "metadata-test", helper, repo, artifacts, scope, previousCommit, sensitiveText], { env: isolatedEnvironment(root), encoding: "utf8" });
    assert.equal(result.status, 23, result.stderr);
    const text = readFileSync(join(artifacts, "run-metadata.json"), "utf8");
    assert.equal(text.includes(sensitiveText), false);
    const metadata = JSON.parse(text);
    assert.equal(metadata.source.commit, scope === "ref" ? previousCommit : currentCommit);
    assert.equal(metadata.source.scope, scope);
    assert.equal(metadata.source.dirty, scope === "working-tree");
    assert.equal(metadata.source.contentIdentity, scope === "working-tree" ? "mutable-working-tree" : "git-archive");
    assert.equal(metadata.exitCode, 23);
    assert.equal(metadata.status, "fail");
    assert.equal(metadata.lastPhase, "execution");
    for (const phase of ["setup", "synchronization", "execution"]) assert.ok(metadata.phaseSeconds[phase] >= 0, phase);
    const phaseTotal = Object.values(metadata.phaseSeconds).reduce((sum, value) => sum + value, 0);
    assert.ok(phaseTotal <= metadata.durationSeconds);
    assert.ok(metadata.durationSeconds - phaseTotal <= metadata.timingResolutionSeconds);
    assert.equal(metadata.wrapperRetryCount, 0);
    assert.equal(metadata.testAttemptCount, null);
  }
});

test("metadata detects untracked source even when Git configuration hides it", (t) => {
  const root = fixture(t);
  const repo = repository(root);
  git(repo, "config", "status.showUntrackedFiles", "no");
  put(repo, "untracked.txt", "source included in working-tree export");
  assert.equal(git(repo, "status", "--porcelain"), "");
  const artifacts = join(root, "metadata");
  mkdirSync(artifacts);
  const result = spawnSync("/bin/bash", ["-c", `
set -euo pipefail
source "$1"
ROOT_DIR="$2" LOCAL_ARTIFACTS_DIR="$3" RUN_LABEL="untracked-fixture"
VALIDATION_SCOPE=working-tree REF_SPEC="" FULL_ARTIFACTS=0
toastty_begin_run_metadata validation macos smoke-ui
`, "metadata-test", helper, repo, artifacts], { env: isolatedEnvironment(root), encoding: "utf8" });
  succeeds(result);
  const metadata = JSON.parse(readFileSync(join(artifacts, "run-metadata.json"), "utf8"));
  assert.equal(metadata.source.dirty, true);
  assert.equal(metadata.source.commit, git(repo, "rev-parse", "HEAD"));
});

test("invalid result JSON produces failure metadata that repeated finalization preserves", (t) => {
  const root = fixture(t);
  const repo = repository(root);
  const invalidResults = ['{"status":', '[{"status":"pass"}]', '{"status":"pass"}\n{"status":"pass"}'];
  for (const [index, invalid] of invalidResults.entries()) {
    const artifacts = join(root, `invalid-${index}`);
    put(artifacts, "result.json", invalid);
    const result = spawnSync("/bin/bash", ["-c", `
set -euo pipefail
source "$1"
ROOT_DIR="$2" LOCAL_ARTIFACTS_DIR="$3" RUN_LABEL="invalid-result-fixture"
VALIDATION_SCOPE=head REF_SPEC="" FULL_ARTIFACTS=0
toastty_begin_run_metadata validation macos smoke-ui
toastty_run_phase artifact-copy
first_rc=0
toastty_finish_run_metadata 0 || first_rc=$?
cp "$LOCAL_ARTIFACTS_DIR/run-metadata.json" "$LOCAL_ARTIFACTS_DIR/first-metadata.json"
printf '%s\\n' '{"status":"pass"}' > "$LOCAL_ARTIFACTS_DIR/result.json"
toastty_finish_run_metadata 0
exit "$first_rc"
`, "metadata-test", helper, repo, artifacts], { env: isolatedEnvironment(root), encoding: "utf8" });
    assert.notEqual(result.status, 0, result.stderr);
    const first = readFileSync(join(artifacts, "first-metadata.json"), "utf8");
    assert.equal(readFileSync(join(artifacts, "run-metadata.json"), "utf8"), first);
    const metadata = JSON.parse(first);
    assert.equal(metadata.status, "fail");
    assert.equal(metadata.exitCode, result.status);
    assert.equal(metadata.lastPhase, "artifact-copy");
    assert.equal(metadata.remoteAllocationConfirmed, false);
  }
});

test("Computer Use stop reports failure when its app process survives TERM", { timeout: 15000 }, async (t) => {
  const root = fixture(t);
  const app = spawn(process.execPath, ["-e", 'process.on("SIGTERM", () => {}); console.log("ready"); setInterval(() => {}, 1000)']);
  t.after(() => { if (app.exitCode === null && app.signalCode === null) app.kill("SIGKILL"); });
  await new Promise((resolve, reject) => {
    app.once("error", reject);
    app.stdout.once("data", resolve);
  });
  const result = spawnSync("/bin/bash", [join(sourceRoot, "scripts/remote/computer-use-run.sh"),
    "--remote-stop", "--socket-path", join(root, "owned.sock"), "--app-pid", String(app.pid)],
  { env: isolatedEnvironment(root), encoding: "utf8", timeout: 10000 });
  assert.equal(result.status, 1, result.stderr);
  assert.equal(app.kill(0), true);
});
