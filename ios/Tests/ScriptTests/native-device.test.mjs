import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testPath = fileURLToPath(import.meta.url);
const iosRoot = path.resolve(path.dirname(testPath), "../..");
const dispatcherPath = path.join(iosRoot, "scripts", "toastty-ios.mjs");

function readyIPhone() {
  return {
    result: {
      devices: [{
        identifier: "CORE-DEVICE-ID",
        hardwareProperties: {
          reality: "physical",
          platform: "iOS",
          deviceType: "iPhone",
          udid: "PHYSICAL-UDID",
        },
        deviceProperties: {
          name: "Test iPhone",
          osVersionNumber: "18.6",
          developerModeStatus: "enabled",
          ddiServicesAvailable: true,
        },
        connectionProperties: {
          pairingState: "paired",
          tunnelState: "connected",
          potentialHostnames: ["test-iphone.local"],
        },
      }],
    },
  };
}

function createPreflightToolchain() {
  const root = mkdtempSync(path.join(os.tmpdir(), "toastty-device-preflight-"));
  const bin = path.join(root, "bin");
  const runRoot = path.join(root, "run");
  const logPath = path.join(root, "commands.jsonl");
  mkdirSync(bin, { recursive: true });
  symlinkSync(process.execPath, path.join(bin, "node"));

  const stubSource = `#!${process.execPath}
const fs = require("node:fs");
const path = require("node:path");
const tool = path.basename(process.argv[1]);
const args = process.argv.slice(2);
fs.appendFileSync(process.env.STUB_LOG, JSON.stringify({ tool, args }) + "\\n");
if (tool === "xcrun" && args[0] === "devicectl" && args[1] === "list") {
  const outputIndex = args.indexOf("--json-output");
  fs.writeFileSync(args[outputIndex + 1], process.env.STUB_DEVICES);
}
`;
  for (const tool of ["codesign", "plutil", "security", "tuist", "xcodebuild", "xcrun"]) {
    writeFileSync(path.join(bin, tool), stubSource, { mode: 0o755 });
  }

  return {
    logPath,
    runRoot,
    environment: {
      ...process.env,
      PATH: `${bin}:/usr/bin:/bin`,
      STUB_LOG: logPath,
      STUB_DEVICES: JSON.stringify(readyIPhone()),
      TOASTTY_IOS_DEVELOPMENT_TEAM: "TEAM123456",
      TOASTTY_IOS_WORKTREE_ID: "script-tests",
      TOASTTY_NATIVE_DEVICE_RUN_ID: "preflight-test",
      TOASTTY_NATIVE_DEVICE_RUN_ROOT: runRoot,
      TOASTTY_NATIVE_DEVICE_DERIVED_DATA_PATH: path.join(runRoot, "DerivedData"),
    },
  };
}

function readCommands(logPath) {
  return readFileSync(logPath, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

test("preflight-only records selected-device evidence without generation, build, install, or launch", () => {
  const toolchain = createPreflightToolchain();
  const result = spawnSync(process.execPath, [
    dispatcherPath,
    "native-device",
    "--preflight-only",
    "--device",
    "test-iphone.local",
  ], {
    cwd: iosRoot,
    env: toolchain.environment,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);

  const preflight = JSON.parse(readFileSync(
    path.join(toolchain.runRoot, "state", "preflight.json"),
    "utf8",
  ));
  assert.equal(preflight.ok, true);
  assert.equal(preflight.buildConfiguration, "Debug");
  assert.equal(preflight.bundleID, "com.giantthings.toastty.mobile.dev");
  assert.equal(preflight.physicalDevice.selectedDevice.udid, "PHYSICAL-UDID");

  const instance = JSON.parse(readFileSync(
    path.join(toolchain.runRoot, "instance.json"),
    "utf8",
  ));
  assert.equal(instance.command, "native-device");
  assert.equal(instance.phase, "preflight-complete");
  assert.equal(instance.physicalDeviceIdentifier, "CORE-DEVICE-ID");
  assert.equal(instance.physicalDeviceUDID, "PHYSICAL-UDID");
  assert.equal(instance.bundleID, "com.giantthings.toastty.mobile.dev");

  const commands = readCommands(toolchain.logPath);
  assert.ok(commands.some(({ tool, args }) => (
    tool === "xcodebuild" && args.join(" ") === "-checkFirstLaunchStatus"
  )));
  assert.ok(commands.some(({ tool, args }) => (
    tool === "xcrun" && args.slice(0, 3).join(" ") === "devicectl list devices"
  )));
  assert.equal(commands.some(({ tool }) => tool === "tuist"), false);
  assert.equal(commands.some(({ args }) => args.includes("install") || args.includes("launch")), false);
});

test("execution fails before tool access when the development team is missing", () => {
  const toolchain = createPreflightToolchain();
  delete toolchain.environment.TOASTTY_IOS_DEVELOPMENT_TEAM;
  const result = spawnSync(process.execPath, [
    dispatcherPath,
    "native-device",
    "--preflight-only",
  ], {
    cwd: iosRoot,
    env: toolchain.environment,
    encoding: "utf8",
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /DEVELOPMENT_TEAM is required/);
});

test("execution rejects traversal-like run identifiers before tool access", () => {
  const toolchain = createPreflightToolchain();
  toolchain.environment.TOASTTY_NATIVE_DEVICE_RUN_ID = "..";
  const result = spawnSync(process.execPath, [
    dispatcherPath,
    "native-device",
    "--preflight-only",
  ], {
    cwd: iosRoot,
    env: toolchain.environment,
    encoding: "utf8",
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /RUN_ID may contain only/);
  assert.throws(() => readFileSync(toolchain.logPath), { code: "ENOENT" });
});
