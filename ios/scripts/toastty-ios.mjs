#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);
const iosRoot = path.resolve(path.dirname(scriptPath), "..");
const workspace = "ToasttyMobile.xcworkspace";
const scheme = "ToasttyMobileApp";
const minimumIOSMajorVersion = 18;
const defaultDeviceNames = [
  "iPhone 17 Pro",
  "iPhone 17",
  "iPhone 16 Pro",
  "iPhone 16e",
  "iPhone 16",
  "iPhone 15 Pro",
  "iPhone 15",
];

class CommandFailure extends Error {
  constructor(message, exitCode = 1) {
    super(message);
    this.exitCode = exitCode;
  }
}

function fail(message) {
  throw new CommandFailure(message);
}

function commandText(executable, args) {
  return [executable, ...args]
    .map((value) => (/^[A-Za-z0-9_./:=,+@%-]+$/.test(value)
      ? value
      : JSON.stringify(value)))
    .join(" ");
}

function runChecked(executable, args, options = {}) {
  process.stderr.write(`[toastty-ios] ${commandText(executable, args)}\n`);
  const result = spawnSync(executable, args, {
    cwd: options.cwd ?? iosRoot,
    env: options.env ?? process.env,
    encoding: options.capture ? "utf8" : undefined,
    stdio: options.capture ? ["ignore", "pipe", "inherit"] : "inherit",
  });

  if (result.error) {
    throw new CommandFailure(
      `failed to run ${executable}: ${result.error.message}`,
    );
  }
  if (result.status !== 0) {
    throw new CommandFailure(
      `${executable} exited with status ${result.status ?? "unknown"}`,
      result.status ?? 1,
    );
  }
  return options.capture ? result.stdout : "";
}

function parseArguments(argv) {
  const command = argv[0] ?? "help";
  let dryRun = false;

  for (const argument of argv.slice(1)) {
    if (argument === "--dry-run" && !dryRun) {
      dryRun = true;
      continue;
    }
    fail(`unexpected ${command} argument: ${argument}`);
  }

  return { command, dryRun };
}

function sanitizeIdentifier(rawValue, { fallback, maximumLength }) {
  const normalized = rawValue
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "") || fallback;

  if (normalized.length <= maximumLength) return normalized;
  const digest = createHash("sha256").update(normalized).digest("hex").slice(0, 8);
  const prefix = normalized
    .slice(0, maximumLength - digest.length - 1)
    .replace(/-+$/g, "");
  return `${prefix}-${digest}`;
}

function resolveWorktreeID() {
  const override = process.env.TOASTTY_IOS_WORKTREE_ID?.trim();
  if (override) return override;

  const root = runChecked("git", ["rev-parse", "--show-toplevel"], { capture: true }).trim();
  if (!root) fail("git returned an empty worktree root");
  return path.basename(root);
}

function parseVersion(rawVersion) {
  const match = String(rawVersion ?? "").match(/^(\d+)(?:\.(\d+))?(?:\.(\d+))?/);
  if (!match) return null;
  return [
    Number.parseInt(match[1], 10),
    Number.parseInt(match[2] ?? "0", 10),
    Number.parseInt(match[3] ?? "0", 10),
  ];
}

function compareVersionsDescending(left, right) {
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const difference = (right[index] ?? 0) - (left[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}

function parseJSON(commandDescription, rawValue) {
  try {
    return JSON.parse(rawValue);
  } catch (error) {
    fail(`${commandDescription} returned invalid JSON: ${error.message}`);
  }
}

function isIOSRuntime(runtime) {
  return runtime?.platform === "iOS"
    || String(runtime?.identifier ?? "").includes(".SimRuntime.iOS-");
}

function selectNewestRuntime(runtimesPayload) {
  const candidates = (runtimesPayload.runtimes ?? [])
    .map((runtime) => ({ runtime, version: parseVersion(runtime?.version) }))
    .filter(({ runtime, version }) => (
      runtime?.isAvailable !== false
      && typeof runtime?.identifier === "string"
      && isIOSRuntime(runtime)
      && version !== null
      && version[0] >= minimumIOSMajorVersion
    ))
    .sort((left, right) => compareVersionsDescending(left.version, right.version));

  if (candidates.length === 0) {
    fail(`no available iOS ${minimumIOSMajorVersion}+ simulator runtime is installed`);
  }
  return candidates[0].runtime;
}

function availableIPhoneDevices(devicesPayload, runtimeIdentifier) {
  const devices = devicesPayload.devices?.[runtimeIdentifier];
  if (!Array.isArray(devices)) return [];
  return devices.filter((device) => (
    device
    && device.isAvailable !== false
    && typeof device.udid === "string"
    && typeof device.name === "string"
    && (device.name.startsWith("iPhone") || device.name.startsWith("Toastty Mobile "))
  ));
}

function preferredDeviceType(runtime) {
  const configuredNames = (process.env.TOASTTY_IOS_SIMULATOR_DEVICE_NAMES ?? "")
    .split(",")
    .map((name) => name.trim())
    .filter(Boolean);
  const preferredNames = configuredNames.length > 0 ? configuredNames : defaultDeviceNames;
  const supportedTypes = Array.isArray(runtime.supportedDeviceTypes)
    ? runtime.supportedDeviceTypes.filter((candidate) => (
      candidate?.productFamily === "iPhone"
      && typeof candidate.identifier === "string"
    ))
    : [];

  for (const preferredName of preferredNames) {
    const match = supportedTypes.find((candidate) => candidate.name === preferredName);
    if (match) return match;
  }
  if (supportedTypes[0]) return supportedTypes[0];
  fail(`iOS runtime ${runtime.version ?? runtime.identifier} exposes no supported iPhone device type`);
}

function resolveSimulator(worktreeComponent, environment) {
  const runtimesPayload = parseJSON(
    "xcrun simctl list runtimes",
    runChecked("xcrun", ["simctl", "list", "runtimes", "available", "--json"], {
      capture: true,
      env: environment,
    }),
  );
  const runtime = selectNewestRuntime(runtimesPayload);
  const devicesPayload = parseJSON(
    "xcrun simctl list devices",
    runChecked("xcrun", ["simctl", "list", "devices", "available", "--json"], {
      capture: true,
      env: environment,
    }),
  );
  const devices = availableIPhoneDevices(devicesPayload, runtime.identifier);
  const simulatorName = `Toastty Mobile ${worktreeComponent}`;
  const booted = devices.find((device) => device.state === "Booted");
  if (booted) {
    return { udid: booted.udid, runtime, created: false, booted: true };
  }

  const existing = devices.find((device) => device.name === simulatorName);
  if (existing) {
    runChecked("xcrun", ["simctl", "boot", existing.udid], { env: environment });
    runChecked("xcrun", ["simctl", "bootstatus", existing.udid, "-b"], { env: environment });
    return { udid: existing.udid, runtime, created: false, booted: false };
  }

  const deviceType = preferredDeviceType(runtime);
  const udid = runChecked(
    "xcrun",
    ["simctl", "create", simulatorName, deviceType.identifier, runtime.identifier],
    { capture: true, env: environment },
  ).trim();
  if (!udid) fail("xcrun simctl create returned an empty simulator identifier");
  runChecked("xcrun", ["simctl", "boot", udid], { env: environment });
  runChecked("xcrun", ["simctl", "bootstatus", udid, "-b"], { env: environment });
  return { udid, runtime, created: true, booted: false };
}

function commandContext(command, dryRun) {
  const rawWorktreeID = process.env.TOASTTY_IOS_WORKTREE_ID?.trim()
    || (dryRun ? path.basename(path.resolve(iosRoot, "..")) : resolveWorktreeID());
  const worktreeComponent = sanitizeIdentifier(rawWorktreeID, {
    fallback: "worktree",
    maximumLength: 40,
  });
  const runID = sanitizeIdentifier(process.env.TOASTTY_IOS_RUN_ID?.trim() || command, {
    fallback: command,
    maximumLength: 48,
  });
  const runRoot = path.resolve(
    process.env.TOASTTY_IOS_RUN_ROOT
      ?? path.join(iosRoot, ".build-runs", worktreeComponent, runID),
  );
  const derivedDataPath = path.resolve(
    process.env.TOASTTY_IOS_DERIVED_DATA_PATH
      ?? path.join(runRoot, "DerivedData"),
  );
  const bundleSuffix = `.dev.${worktreeComponent}`;
  const environment = {
    ...process.env,
    TUIST_TOASTTY_MOBILE_BUNDLE_SUFFIX: bundleSuffix,
    TOASTTY_IOS_DERIVED_DATA_PATH: derivedDataPath,
    TOASTTY_IOS_RUN_ROOT: runRoot,
    TOASTTY_IOS_WORKTREE_ID: rawWorktreeID,
  };

  return {
    bundleSuffix,
    derivedDataPath,
    environment,
    rawWorktreeID,
    runID,
    runRoot,
    worktreeComponent,
  };
}

function generationSteps() {
  return [
    { executable: "tuist", args: ["install"] },
    { executable: "tuist", args: ["generate", "--no-open"] },
  ];
}

function performGeneration(environment) {
  for (const step of generationSteps()) {
    runChecked(step.executable, step.args, { env: environment });
  }
}

function xcodebuildArguments(command, context, destination) {
  const configuration = process.env.TOASTTY_IOS_CONFIGURATION?.trim() || "Debug";
  if (configuration !== "Debug" && configuration !== "Release") {
    fail("TOASTTY_IOS_CONFIGURATION must be Debug or Release");
  }
  return [
    "-workspace",
    workspace,
    "-scheme",
    scheme,
    "-configuration",
    configuration,
    "-destination",
    destination,
    "-derivedDataPath",
    context.derivedDataPath,
    command,
  ];
}

function dryRunPlan(command, context) {
  const steps = generationSteps();
  if (command !== "generate") {
    const destinationOverride = process.env.TOASTTY_IOS_DESTINATION?.trim();
    const destination = destinationOverride
      || `<auto:newest-available-iOS-${minimumIOSMajorVersion}+-simulator>`;
    if (!destinationOverride) {
      steps.push({
        operation: "resolve-simulator",
        minimumIOSMajorVersion,
        newestRuntimeOnly: true,
        reuseBootedOnSelectedRuntime: true,
        isolatedSimulatorName: `Toastty Mobile ${context.worktreeComponent}`,
      });
    }
    steps.push({
      executable: "xcodebuild",
      args: xcodebuildArguments(command, context, destination),
    });
  }

  return {
    command,
    dryRun: true,
    cwd: iosRoot,
    workspace,
    scheme,
    worktreeID: context.rawWorktreeID,
    worktreeComponent: context.worktreeComponent,
    bundleSuffix: context.bundleSuffix,
    runRoot: context.runRoot,
    derivedDataPath: context.derivedDataPath,
    environment: {
      TUIST_TOASTTY_MOBILE_BUNDLE_SUFFIX: context.bundleSuffix,
      TOASTTY_IOS_RUN_ROOT: context.runRoot,
      TOASTTY_IOS_DERIVED_DATA_PATH: context.derivedDataPath,
    },
    steps,
  };
}

function printHelp() {
  process.stdout.write(`Usage: node ios/scripts/toastty-ios.mjs <command> [--dry-run]\n\nCommands:\n  generate  Install Tuist packages and generate the Xcode workspace\n  build     Generate, select an iOS 18+ simulator, and build the app\n  test      Generate, select an iOS 18+ simulator, and run all app tests\n\nEnvironment:\n  TOASTTY_IOS_CONFIGURATION          Debug or Release (default: Debug)\n  TOASTTY_IOS_DESTINATION            Explicit xcodebuild destination override\n  TOASTTY_IOS_SIMULATOR_DEVICE_NAMES Preferred iPhone names, comma-separated\n  TOASTTY_IOS_RUN_ID                 Filesystem-safe run label\n  TOASTTY_IOS_RUN_ROOT               Isolated run directory override\n  TOASTTY_IOS_DERIVED_DATA_PATH      DerivedData directory override\n  TOASTTY_IOS_WORKTREE_ID            Worktree identity override\n`);
}

function main() {
  const { command, dryRun } = parseArguments(process.argv.slice(2));
  if (command === "help") {
    if (dryRun) fail("help does not accept --dry-run");
    printHelp();
    return;
  }
  if (!["generate", "build", "test"].includes(command)) {
    printHelp();
    throw new CommandFailure(`unknown command: ${command}`);
  }

  const context = commandContext(command, dryRun);
  if (dryRun) {
    process.stdout.write(`${JSON.stringify(dryRunPlan(command, context), null, 2)}\n`);
    return;
  }

  performGeneration(context.environment);
  if (command === "generate") return;

  const destinationOverride = process.env.TOASTTY_IOS_DESTINATION?.trim();
  const simulator = destinationOverride
    ? null
    : resolveSimulator(context.worktreeComponent, context.environment);
  const destination = destinationOverride
    || `platform=iOS Simulator,id=${simulator.udid}`;
  runChecked(
    "xcodebuild",
    xcodebuildArguments(command, context, destination),
    { env: context.environment },
  );
}

try {
  main();
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`[toastty-ios] error: ${message}\n`);
  process.exitCode = error instanceof CommandFailure ? error.exitCode : 1;
}
