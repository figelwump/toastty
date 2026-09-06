import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testPath = fileURLToPath(import.meta.url);
const iosRoot = path.resolve(path.dirname(testPath), "../..");
const dispatcherPath = path.join(iosRoot, "scripts", "toastty-ios.mjs");
const projectManifestPath = path.join(iosRoot, "Project.swift");

function runDispatcher(args, environment = {}) {
  const childEnvironment = { ...process.env };
  for (const key of [
    "TOASTTY_IOS_CONFIGURATION",
    "TOASTTY_IOS_DERIVED_DATA_PATH",
    "TOASTTY_IOS_DESTINATION",
    "TOASTTY_IOS_RUN_ID",
    "TOASTTY_IOS_RUN_ROOT",
    "TOASTTY_IOS_SIMULATOR_DEVICE_NAMES",
    "TOASTTY_IOS_WORKTREE_ID",
    "TOASTTY_IOS_DEVELOPMENT_TEAM",
    "TOASTTY_NATIVE_DEVICE_DERIVED_DATA_PATH",
    "TOASTTY_NATIVE_DEVICE_RUN_ID",
    "TOASTTY_NATIVE_DEVICE_RUN_LOCK_DIR",
    "TOASTTY_NATIVE_DEVICE_RUN_ROOT",
    "TUIST_TOASTTY_MOBILE_BUNDLE_SUFFIX",
    "TUIST_TOASTTY_MOBILE_DEVELOPMENT_TEAM",
    "TUIST_TOASTTY_MOBILE_PHYSICAL_DEVICE",
  ]) {
    delete childEnvironment[key];
  }
  Object.assign(childEnvironment, {
    TOASTTY_IOS_WORKTREE_ID: "script-tests",
    ...environment,
  });

  return spawnSync(process.execPath, [dispatcherPath, ...args], {
    cwd: iosRoot,
    env: childEnvironment,
    encoding: "utf8",
  });
}

function readLog(logPath) {
  try {
    return readFileSync(logPath, "utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
}

function createStubToolchain({ runtimes, devices, createUDID = "CREATED-UDID", failure } = {}) {
  const root = mkdtempSync(path.join(os.tmpdir(), "toastty-ios-script-test-"));
  const logPath = path.join(root, "commands.jsonl");
  const stubSource = `#!${process.execPath}
const fs = require("node:fs");
const path = require("node:path");
const tool = path.basename(process.argv[1]);
const args = process.argv.slice(2);
fs.appendFileSync(process.env.STUB_LOG, JSON.stringify({
  tool,
  args,
  bundleSuffix: process.env.TUIST_TOASTTY_MOBILE_BUNDLE_SUFFIX,
  developmentTeam: process.env.TUIST_TOASTTY_MOBILE_DEVELOPMENT_TEAM,
  runRoot: process.env.TOASTTY_IOS_RUN_ROOT,
  derivedDataPath: process.env.TOASTTY_IOS_DERIVED_DATA_PATH,
}) + "\\n");
const failure = JSON.parse(process.env.STUB_FAILURE || "null");
if (failure && failure.tool === tool && (failure.args == null || JSON.stringify(args) === JSON.stringify(failure.args))) {
  process.exit(failure.status);
}
if (tool === "xcrun" && args.join(" ") === "simctl list runtimes available --json") {
  process.stdout.write(process.env.STUB_RUNTIMES);
} else if (tool === "xcrun" && args.join(" ") === "simctl list devices available --json") {
  process.stdout.write(process.env.STUB_DEVICES);
} else if (tool === "xcrun" && args[0] === "simctl" && args[1] === "create") {
  process.stdout.write(process.env.STUB_CREATE_UDID + "\\n");
}
`;

  for (const tool of ["tuist", "xcrun", "xcodebuild"]) {
    const target = path.join(root, tool);
    writeFileSync(target, stubSource, { mode: 0o755 });
  }

  return {
    logPath,
    environment: {
      PATH: root,
      STUB_LOG: logPath,
      STUB_RUNTIMES: JSON.stringify(runtimes ?? { runtimes: [] }),
      STUB_DEVICES: JSON.stringify(devices ?? { devices: {} }),
      STUB_CREATE_UDID: createUDID,
      STUB_FAILURE: JSON.stringify(failure ?? null),
      TOASTTY_IOS_RUN_ROOT: path.join(root, "run"),
    },
  };
}

function runtime(identifier, version) {
  return {
    identifier,
    version,
    platform: "iOS",
    isAvailable: true,
    supportedDeviceTypes: [{
      name: "iPhone 17",
      identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
      productFamily: "iPhone",
    }],
  };
}

test("all commands have stable, tool-free dry-run plans", () => {
  for (const command of ["generate", "build", "test"]) {
    const environment = {
      PATH: "",
      TOASTTY_IOS_WORKTREE_ID: "Feature / Mobile iOS!",
      TOASTTY_IOS_RUN_ROOT: "/tmp/toastty-ios-dry-run",
      TOASTTY_IOS_DERIVED_DATA_PATH: "/tmp/toastty-ios-dry-run/DerivedData",
    };
    const first = runDispatcher([command, "--dry-run"], environment);
    const second = runDispatcher([command, "--dry-run"], environment);
    assert.equal(first.status, 0, first.stderr);
    assert.equal(second.status, 0, second.stderr);
    assert.equal(first.stdout, second.stdout);

    const plan = JSON.parse(first.stdout);
    assert.equal(plan.command, command);
    assert.equal(plan.dryRun, true);
    assert.deepEqual(plan.steps.slice(0, 2), [
      { executable: "tuist", args: ["install"] },
      { executable: "tuist", args: ["generate", "--no-open"] },
    ]);
    assert.equal(plan.bundleSuffix, ".dev.feature-mobile-ios");
    assert.equal(`com.giantthings.toastty.mobile${plan.bundleSuffix}`, "com.giantthings.toastty.mobile.dev.feature-mobile-ios");
    assert.equal(plan.environment.TUIST_TOASTTY_MOBILE_BUNDLE_SUFFIX, plan.bundleSuffix);
  }
});

test("Tuist generation keeps the repository development team unless overridden", () => {
  const manifest = readFileSync(projectManifestPath, "utf8");

  assert.match(
    manifest,
    /let developmentTeam = manifestValue\([\s\S]*?"TUIST_TOASTTY_MOBILE_DEVELOPMENT_TEAM"[\s\S]*?"TOASTTY_IOS_DEVELOPMENT_TEAM"[\s\S]*?default: "SP7JP8254U"[\s\S]*?\)/,
  );
  assert.match(manifest, /appSettings\["CODE_SIGN_STYLE"\] = "Automatic"/);
  assert.match(
    manifest,
    /appSettings\["DEVELOPMENT_TEAM"\] = SettingValue\(stringLiteral: developmentTeam\)/,
  );
  assert.doesNotMatch(manifest, /appSettings\["DEVELOPMENT_TEAM"\] = ""/);
});

test("generation forwards the public development-team override to Tuist", () => {
  const toolchain = createStubToolchain();
  const result = runDispatcher(["generate"], {
    ...toolchain.environment,
    TOASTTY_IOS_DEVELOPMENT_TEAM: "TEAM123456",
  });

  assert.equal(result.status, 0, result.stderr);
  const commands = readLog(toolchain.logPath);
  assert.deepEqual(commands.map(({ tool, args }) => [tool, args]), [
    ["tuist", ["install"]],
    ["tuist", ["generate", "--no-open"]],
  ]);
  assert.ok(commands.every(({ developmentTeam }) => developmentTeam === "TEAM123456"));
});

test("bundle suffix sanitization is deterministic, bounded, and collision-resistant when truncated", () => {
  const raw = "  123/Feature_This Is A Very Long Worktree Name With Ünicode And Punctuation!!!  ";
  const result = runDispatcher(["generate", "--dry-run"], {
    PATH: "",
    TOASTTY_IOS_WORKTREE_ID: raw,
    TOASTTY_IOS_RUN_ROOT: "/tmp/toastty-ios-suffix",
  });
  assert.equal(result.status, 0, result.stderr);
  const plan = JSON.parse(result.stdout);
  assert.match(plan.worktreeComponent, /^[a-z0-9-]+-[a-f0-9]{8}$/);
  assert.ok(plan.worktreeComponent.length <= 40);
  assert.equal(plan.bundleSuffix, `.dev.${plan.worktreeComponent}`);
});

test("native-device dry-run pins the fixed Debug identity without invoking tools", () => {
  const environment = {
    PATH: "",
    TOASTTY_IOS_DEVELOPMENT_TEAM: "TEAM123456",
    TOASTTY_NATIVE_DEVICE_RUN_ID: "device-dry-run",
    TOASTTY_NATIVE_DEVICE_RUN_ROOT: "/tmp/toastty-device-dry-run",
  };
  const first = runDispatcher([
    "native-device",
    "--dry-run",
    "--preflight-only",
    "--device",
    "TEST-UDID",
  ], environment);
  const second = runDispatcher([
    "native-device",
    "--dry-run",
    "--preflight-only",
    "--device",
    "TEST-UDID",
  ], environment);
  assert.equal(first.status, 0, first.stderr);
  assert.equal(second.status, 0, second.stderr);
  assert.equal(first.stdout, second.stdout);

  const plan = JSON.parse(first.stdout);
  assert.equal(plan.command, "native-device");
  assert.equal(plan.buildConfiguration, "Debug");
  assert.equal(plan.bundleID, "com.giantthings.toastty.mobile.dev");
  assert.equal(plan.developmentTeam, "TEAM123456");
  assert.equal(plan.device, "TEST-UDID");
  assert.equal(plan.preflightOnly, true);
  assert.equal(plan.physicalDeviceManifestFlag, true);
  assert.equal(plan.environment.TUIST_TOASTTY_MOBILE_BUNDLE_SUFFIX, ".dev.local");
  assert.equal(plan.environment.TUIST_TOASTTY_MOBILE_PHYSICAL_DEVICE, "1");
  assert.deepEqual(plan.args, ["scripts/dev/native-device.sh"]);
});

test("native-device rejects conflicting or incomplete options before spawning", () => {
  const conflict = runDispatcher([
    "native-device",
    "--preflight-only",
    "--build-only",
  ], { PATH: "" });
  assert.equal(conflict.status, 1);
  assert.match(conflict.stderr, /cannot be combined/);

  const missingDevice = runDispatcher(["native-device", "--device"], { PATH: "" });
  assert.equal(missingDevice.status, 1);
  assert.match(missingDevice.stderr, /--device requires a value/);
});

test("a booted iOS 17 device is rejected in favor of creating on the newest compatible runtime", () => {
  const ios17 = "com.apple.CoreSimulator.SimRuntime.iOS-17-5";
  const ios18 = "com.apple.CoreSimulator.SimRuntime.iOS-18-4";
  const toolchain = createStubToolchain({
    runtimes: { runtimes: [runtime(ios17, "17.5"), runtime(ios18, "18.4")] },
    devices: {
      devices: {
        [ios17]: [{ name: "iPhone 15", udid: "IOS17-BOOTED", state: "Booted", isAvailable: true }],
        [ios18]: [],
      },
    },
  });

  const result = runDispatcher(["build"], toolchain.environment);
  assert.equal(result.status, 0, result.stderr);
  const commands = readLog(toolchain.logPath);
  const create = commands.find(({ tool, args }) => tool === "xcrun" && args[1] === "create");
  assert.ok(create, "expected a compatible simulator to be created");
  assert.equal(create.args.at(-1), ios18);
  const build = commands.find(({ tool }) => tool === "xcodebuild");
  assert.equal(build.args[build.args.indexOf("-destination") + 1], "platform=iOS Simulator,id=CREATED-UDID");
  assert.ok(!JSON.stringify(commands).includes("id=IOS17-BOOTED"));
});

test("the newest compatible runtime does not reuse an unrelated booted iPhone", () => {
  const ios18 = "com.apple.CoreSimulator.SimRuntime.iOS-18-4";
  const ios19 = "com.apple.CoreSimulator.SimRuntime.iOS-19-1";
  const toolchain = createStubToolchain({
    runtimes: { runtimes: [runtime(ios18, "18.4"), runtime(ios19, "19.1")] },
    devices: {
      devices: {
        [ios18]: [{ name: "iPhone 16", udid: "OLDER-BOOTED", state: "Booted", isAvailable: true }],
        [ios19]: [{ name: "iPhone 17", udid: "NEWEST-BOOTED", state: "Booted", isAvailable: true }],
      },
    },
  });

  const result = runDispatcher(["test"], toolchain.environment);
  assert.equal(result.status, 0, result.stderr);
  const commands = readLog(toolchain.logPath);
  assert.deepEqual(commands.slice(0, 2).map(({ tool, args }) => [tool, args]), [
    ["tuist", ["install"]],
    ["tuist", ["generate", "--no-open"]],
  ]);
  assert.equal(commands.filter(({ tool, args }) => tool === "xcrun" && args[1] === "create").length, 1);
  assert.equal(commands.filter(({ tool, args }) => tool === "xcrun" && ["boot", "bootstatus"].includes(args[1])).length, 2);
  const xcodebuild = commands.find(({ tool }) => tool === "xcodebuild");
  assert.equal(xcodebuild.args[xcodebuild.args.indexOf("-destination") + 1], "platform=iOS Simulator,id=CREATED-UDID");
  assert.deepEqual(
    xcodebuild.args.slice(xcodebuild.args.indexOf("-parallel-testing-enabled"), -1),
    ["-parallel-testing-enabled", "NO"],
  );
  assert.equal(xcodebuild.args.at(-1), "test");
});

test("duplicate isolated simulator names fail closed", () => {
  const ios18 = "com.apple.CoreSimulator.SimRuntime.iOS-18-4";
  const duplicate = {
    name: "Toastty Mobile script-tests",
    state: "Shutdown",
    isAvailable: true,
  };
  const toolchain = createStubToolchain({
    runtimes: { runtimes: [runtime(ios18, "18.4")] },
    devices: {
      devices: {
        [ios18]: [
          { ...duplicate, udid: "DUPLICATE-ONE" },
          { ...duplicate, udid: "DUPLICATE-TWO" },
        ],
      },
    },
  });

  const result = runDispatcher(["test"], toolchain.environment);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /refusing ambiguous targeting/);
  assert.equal(readLog(toolchain.logPath).some(({ tool }) => tool === "xcodebuild"), false);
});

test("an existing isolated simulator on the newest runtime is booted and reused", () => {
  const ios18 = "com.apple.CoreSimulator.SimRuntime.iOS-18-4";
  const toolchain = createStubToolchain({
    runtimes: { runtimes: [runtime(ios18, "18.4")] },
    devices: {
      devices: {
        [ios18]: [{
          name: "Toastty Mobile script-tests",
          udid: "ISOLATED-SHUTDOWN",
          state: "Shutdown",
          isAvailable: true,
        }],
      },
    },
  });

  const result = runDispatcher(["build"], toolchain.environment);
  assert.equal(result.status, 0, result.stderr);
  const commands = readLog(toolchain.logPath);
  assert.ok(
    commands.some(({ tool, args }) => tool === "xcrun" && args.join(" ") === "simctl boot ISOLATED-SHUTDOWN"),
    JSON.stringify(commands, null, 2),
  );
  assert.ok(
    commands.some(({ tool, args }) => tool === "xcrun" && args.join(" ") === "simctl bootstatus ISOLATED-SHUTDOWN -b"),
    JSON.stringify(commands, null, 2),
  );
  assert.equal(commands.filter(({ tool, args }) => tool === "xcrun" && args[1] === "create").length, 0);
});

test("tool failures propagate their exit status and stop later commands", () => {
  const toolchain = createStubToolchain({
    failure: { tool: "tuist", args: ["install"], status: 23 },
  });
  const result = runDispatcher(["test"], toolchain.environment);
  assert.equal(result.status, 23);
  assert.match(result.stderr, /tuist exited with status 23/);
  assert.deepEqual(readLog(toolchain.logPath).map(({ tool, args }) => [tool, args]), [
    ["tuist", ["install"]],
  ]);
});

test("xcodebuild failures propagate after simulator setup", () => {
  const ios18 = "com.apple.CoreSimulator.SimRuntime.iOS-18-4";
  const toolchain = createStubToolchain({
    runtimes: { runtimes: [runtime(ios18, "18.4")] },
    devices: {
      devices: {
        [ios18]: [{ name: "iPhone 17", udid: "BUILD-BOOTED", state: "Booted", isAvailable: true }],
      },
    },
    failure: { tool: "xcodebuild", status: 47 },
  });
  const result = runDispatcher(["test"], toolchain.environment);
  assert.equal(result.status, 47);
  assert.match(result.stderr, /xcodebuild exited with status 47/);
  assert.equal(readLog(toolchain.logPath).at(-1).tool, "xcodebuild");
});

test("destination overrides remain one spawn argument", () => {
  const toolchain = createStubToolchain();
  const destination = "platform=iOS Simulator,name=iPhone 17; echo not-a-shell";
  const result = runDispatcher(["build"], {
    ...toolchain.environment,
    TOASTTY_IOS_DESTINATION: destination,
  });
  assert.equal(result.status, 0, result.stderr);
  const commands = readLog(toolchain.logPath);
  assert.equal(commands.filter(({ tool }) => tool === "xcrun").length, 0);
  const xcodebuild = commands.find(({ tool }) => tool === "xcodebuild");
  assert.equal(xcodebuild.args[xcodebuild.args.indexOf("-destination") + 1], destination);

  const dryRun = runDispatcher(["build", "--dry-run"], {
    PATH: "",
    TOASTTY_IOS_DESTINATION: destination,
    TOASTTY_IOS_RUN_ROOT: "/tmp/toastty-ios-destination-dry-run",
  });
  assert.equal(dryRun.status, 0, dryRun.stderr);
  const plan = JSON.parse(dryRun.stdout);
  assert.equal(plan.steps.some((step) => step.operation === "resolve-simulator"), false);
  assert.equal(plan.steps.at(-1).args[plan.steps.at(-1).args.indexOf("-destination") + 1], destination);
});

test("Release tests exercise app and domain branches without Debug fixture UI launches", () => {
  for (const configuration of ["Debug", "Release"]) {
    const toolchain = createStubToolchain();
    const result = runDispatcher(["test"], {
      ...toolchain.environment,
      TOASTTY_IOS_CONFIGURATION: configuration,
      TOASTTY_IOS_DESTINATION: "platform=iOS Simulator,id=STUB-DEVICE",
    });
    assert.equal(result.status, 0, result.stderr);
    const args = readLog(toolchain.logPath).find(({ tool }) => tool === "xcodebuild").args;
    assert.equal(args[args.indexOf("-configuration") + 1], configuration);
    assert.equal(args.at(-1), "test");
    assert.equal(args.includes("ENABLE_TESTABILITY=YES"), configuration === "Release");
    assert.deepEqual(args.filter((arg) => arg.startsWith("-only-testing:")),
      configuration === "Release" ? [
        "-only-testing:ToasttyMobileAppTests",
        "-only-testing:ToasttyMobileDomainTests",
      ] : []);
    assert.ok(!args.some((arg) => arg.includes("SWIFT_ACTIVE_COMPILATION_CONDITIONS")));
  }
});
