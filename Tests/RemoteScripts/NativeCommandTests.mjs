import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const wrapper = fileURLToPath(new URL("../../scripts/remote/test.sh", import.meta.url));

for (const { platform, buildOnly, flags } of [
  { platform: "macos", buildOnly: true, flags: [] },
  { platform: "macos", buildOnly: false, flags: ["-scheme", "CoreState", "-jobs", "2"] },
  { platform: "ios", buildOnly: true, flags: [] },
]) {
  test(`${platform} ${buildOnly ? "build-only" : "test"} executes the selected action and build budget`, (t) => {
    const root = mkdtempSync(join(tmpdir(), "toastty-native-command-"));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    const source = join(root, "source"), run = join(root, "run"), bin = join(root, "bin");
    for (const path of [join(source, "scripts/dev"), join(source, "toastty.xcodeproj"), run, bin]) mkdirSync(path, { recursive: true });
    writeFileSync(join(source, "scripts/dev/bootstrap-worktree.sh"), "#!/bin/bash\nexit 0\n", { mode: 0o755 });
    writeFileSync(join(source, "toastty.xcodeproj/project.pbxproj"), "TOASTTY_HAS_GHOSTTY_KIT\n");
    // The real remote test control flow runs; native tools are replaced by
    // recorders, so these fixtures cannot start a build, app or simulator.
    writeFileSync(join(bin, "xcodebuild"), '#!/bin/bash\nprintf "%s\\n" "$@" >"$COMMAND_ARGS"\n', { mode: 0o755 });
    for (const name of ["node", "caffeinate"]) writeFileSync(join(bin, name), "#!/bin/bash\nexit 0\n", { mode: 0o755 });
    writeFileSync(join(bin, "xcrun"), "#!/bin/bash\necho 'unexpected simulator operation' >&2\nexit 99\n", { mode: 0o755 });
    const recorded = join(root, "args");
    const result = spawnSync("/bin/bash", [wrapper, "--remote-exec"], {
      cwd: source, encoding: "utf8", timeout: 15_000,
      env: { ...process.env, PATH: `${bin}:/usr/bin:/bin:/usr/sbin:/sbin`,
        COMMAND_ARGS: recorded, ARCH: "arm64", TOASTTY_REMOTE_BUILD_JOBS: "4",
        TOASTTY_REMOTE_TEST_RUN_LABEL: "command-fixture", TOASTTY_REMOTE_TEST_REMOTE_RUN_ROOT: run,
        TOASTTY_REMOTE_TEST_REMOTE_WORKTREE_DIR: source,
        TOASTTY_REMOTE_TEST_XCODEBUILD_ARGS_B64: flags.length ? Buffer.from(flags.join("\n")).toString("base64") : "__toastty_default_xcodebuild_args__",
        TOASTTY_REMOTE_TEST_PLATFORM: platform, TOASTTY_REMOTE_TEST_BUILD_ONLY: buildOnly ? "1" : "0",
        TOASTTY_REMOTE_TEST_TIMEOUT_SECONDS: "5" },
    });
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    const args = readFileSync(recorded, "utf8").trim().split("\n");
    assert.equal(args.at(-1), buildOnly ? "build" : "test");
    assert.equal(args[args.indexOf("-jobs") + 1], flags.length ? "2" : "4");
    if (platform === "ios") assert.equal(args[args.indexOf("-destination") + 1], "generic/platform=iOS Simulator");
  });
}
