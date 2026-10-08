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
  const options = {
    command,
    dryRun: false,
    preflightOnly: false,
    buildOnly: false,
    device: undefined,
    uiTests: undefined,
    skipPerformanceBudgets: false,
  };

  const argumentsForCommand = argv.slice(1);
  for (let index = 0; index < argumentsForCommand.length; index += 1) {
    const argument = argumentsForCommand[index];
    if (argument === "--dry-run" && !options.dryRun) {
      options.dryRun = true;
      continue;
    }
    if (command === "test" && argument === "--ui-tests" && options.uiTests === undefined) {
      const value = argumentsForCommand[index + 1];
      if (value !== "smoke" && value !== "all") {
        fail("--ui-tests requires smoke or all");
      }
      options.uiTests = value;
      index += 1;
      continue;
    }
    if (command === "test" && argument === "--skip-performance-budgets" && !options.skipPerformanceBudgets) {
      options.skipPerformanceBudgets = true;
      continue;
    }
    if (command === "native-device") {
      if (argument === "--preflight-only" && !options.preflightOnly) {
        options.preflightOnly = true;
        continue;
      }
      if (argument === "--build-only" && !options.buildOnly) {
        options.buildOnly = true;
        continue;
      }
      if (argument === "--device" && options.device === undefined) {
        const value = argumentsForCommand[index + 1]?.trim();
        if (!value || value.startsWith("--")) fail("--device requires a value");
        options.device = value;
        index += 1;
        continue;
      }
    }
    fail(`unexpected ${command} argument: ${argument}`);
  }

  if (options.preflightOnly && options.buildOnly) {
    fail("--preflight-only and --build-only cannot be combined");
  }
  return options;
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
  const matchingDevices = devices.filter((device) => device.name === simulatorName);
  if (matchingDevices.length > 1) {
    fail(`multiple simulators are named ${simulatorName}; refusing ambiguous targeting`);
  }

  const existing = matchingDevices[0];
  if (existing) {
    if (existing.state !== "Booted") {
      runChecked("xcrun", ["simctl", "boot", existing.udid], { env: environment });
      runChecked("xcrun", ["simctl", "bootstatus", existing.udid, "-b"], { env: environment });
    }
    return { udid: existing.udid, runtime, created: false, booted: existing.state === "Booted" };
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
  if (
    environment.TUIST_TOASTTY_MOBILE_DEVELOPMENT_TEAM === undefined
    && environment.TOASTTY_IOS_DEVELOPMENT_TEAM !== undefined
  ) {
    environment.TUIST_TOASTTY_MOBILE_DEVELOPMENT_TEAM = environment.TOASTTY_IOS_DEVELOPMENT_TEAM;
  }

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

function selectedScheme(command) {
  return command === "test" && process.env.TOASTTY_IOS_CONFIGURATION?.trim() === "Release"
    ? "ToasttyMobileApp-Release"
    : scheme;
}

function xcodebuildArguments(command, context, destination, uiTests, skipPerformanceBudgets) {
  const configuration = process.env.TOASTTY_IOS_CONFIGURATION?.trim() || "Debug";
  if (configuration !== "Debug" && configuration !== "Release") {
    fail("TOASTTY_IOS_CONFIGURATION must be Debug or Release");
  }
  const args = [
    "-workspace",
    workspace,
    "-scheme",
    selectedScheme(command),
    "-configuration",
    configuration,
    "-destination",
    destination,
    "-derivedDataPath",
    context.derivedDataPath,
  ];
  // The scheme contains unit and UI test bundles. Xcode can starve an async
  // unit-test runner while preparing the UI runner when target parallelism is
  // enabled, producing nondeterministic handshake timeouts. Tests within each
  // bundle still exercise their intended concurrency.
  if (command === "test") {
    // Let the selected simulator determine the architecture, including on Intel hosts.
    // Keep this invocation-scoped so device builds and archives retain their settings.
    args.push("-parallel-testing-enabled", "NO", "ONLY_ACTIVE_ARCH=YES");
    if (configuration === "Release") {
      // Keep Release compilation branches while allowing unit tests to import
      // internal declarations. Fixture-driven UI launches require Debug.
      args.push(
        "ENABLE_TESTABILITY=YES",
        "-only-testing:ToasttyMobileAppTests",
        "-only-testing:ToasttyMobileDomainTests",
      );
    } else if (uiTests === "smoke") {
      args.push(
        "-only-testing:ToasttyMobileAppTests",
        "-only-testing:ToasttyMobileDomainTests",
        "-only-testing:ToasttyMobileUITests/ToasttyMobileFixtureUITests/testFixtureNavigationShowsWorkspaceAndReadOnlyInteraction",
        "-only-testing:ToasttyMobileUITests/ToasttyMobileFixtureUITests/testGatedSendClearsDraftOnlyAfterEnqueueAndShowsOptimisticBubble",
      );
    }
    if (skipPerformanceBudgets) {
      args.push("-skip-testing:ToasttyMobileDomainTests/ConversationRuntimePerformanceTests/testFiveThousandEventDecodeAndReduceStaysWithinProvisionalBudgets");
    }
  }
  args.push(command);
  return args;
}

function dryRunPlan(command, context, uiTests, skipPerformanceBudgets) {
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
      args: xcodebuildArguments(command, context, destination, uiTests, skipPerformanceBudgets),
    });
  }

  return {
    command,
    dryRun: true,
    cwd: iosRoot,
    workspace,
    scheme: selectedScheme(command),
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

function nativeDeviceSpec(options, context) {
  const developmentTeam = (
    process.env.TOASTTY_IOS_DEVELOPMENT_TEAM
    ?? process.env.TUIST_TOASTTY_MOBILE_DEVELOPMENT_TEAM
    ?? ""
  ).trim();
  const runRootOverride = process.env.TOASTTY_NATIVE_DEVICE_RUN_ROOT?.trim();
  const derivedDataOverride = process.env.TOASTTY_NATIVE_DEVICE_DERIVED_DATA_PATH?.trim();
  const runIDOverride = process.env.TOASTTY_NATIVE_DEVICE_RUN_ID?.trim();
  const environment = {
    ...process.env,
    TOASTTY_NATIVE_DEVICE_BUILD_ONLY: options.buildOnly ? "1" : "0",
    TOASTTY_NATIVE_DEVICE_BUNDLE_ID: "com.giantthings.toastty.mobile.dev",
    TOASTTY_NATIVE_DEVICE_BUILD_CONFIGURATION: "Debug",
    TOASTTY_NATIVE_DEVICE_DEVELOPMENT_TEAM: developmentTeam,
    TOASTTY_NATIVE_DEVICE_DISPLAY_NAME: "Toastty Dev",
    TOASTTY_NATIVE_DEVICE_PREFLIGHT_ONLY: options.preflightOnly ? "1" : "0",
    TOASTTY_NATIVE_DEVICE_REQUESTED: options.device ?? "",
    TOASTTY_NATIVE_DEVICE_URL_SCHEME: "toastty-mobile-dev",
    TOASTTY_NATIVE_DEVICE_PUSH_PROBE: pushProbeEnabled() ? "1" : "0",
    TUIST_TOASTTY_MOBILE_BUNDLE_SUFFIX: ".dev.local",
    TUIST_TOASTTY_MOBILE_DEVELOPMENT_TEAM: developmentTeam,
    TUIST_TOASTTY_MOBILE_PHYSICAL_DEVICE: "1",
  };
  if (runIDOverride) environment.TOASTTY_NATIVE_DEVICE_RUN_ID = runIDOverride;
  if (runRootOverride) environment.TOASTTY_NATIVE_DEVICE_RUN_ROOT = runRootOverride;
  if (derivedDataOverride) {
    environment.TOASTTY_NATIVE_DEVICE_DERIVED_DATA_PATH = derivedDataOverride;
  }

  delete environment.TUIST_TOASTTY_MOBILE_PROD_TEST;
  delete environment.TUIST_TOASTTY_MOBILE_RELEASE_CODE_SIGN_IDENTITY;
  delete environment.TUIST_TOASTTY_MOBILE_RELEASE_PROVISIONING_PROFILE_SPECIFIER;

  return {
    executable: "bash",
    args: ["scripts/dev/native-device.sh"],
    environment,
    summary: {
      command: "native-device",
      dryRun: options.dryRun,
      cwd: iosRoot,
      executable: "bash",
      args: ["scripts/dev/native-device.sh"],
      buildConfiguration: "Debug",
      buildOnly: options.buildOnly,
      bundleID: "com.giantthings.toastty.mobile.dev",
      developmentTeam: developmentTeam || null,
      device: options.device ?? null,
      displayName: "Toastty Dev",
      physicalDeviceManifestFlag: true,
      pushProbe: pushProbeEnabled(),
      pushNotifications: Boolean(process.env.TUIST_TOASTTY_MOBILE_PUSH_RELAY_URL),
      preflightOnly: options.preflightOnly,
      runID: runIDOverride || "<auto:UTC-timestamp-pid>",
      runRoot: runRootOverride || null,
      urlScheme: "toastty-mobile-dev",
      environment: {
        TOASTTY_NATIVE_DEVICE_BUILD_CONFIGURATION: "Debug",
        TOASTTY_NATIVE_DEVICE_BUNDLE_ID: "com.giantthings.toastty.mobile.dev",
        TUIST_TOASTTY_MOBILE_BUNDLE_SUFFIX: ".dev.local",
        TUIST_TOASTTY_MOBILE_PHYSICAL_DEVICE: "1",
        TUIST_TOASTTY_MOBILE_PUSH_PROBE: pushProbeEnabled() ? "1" : "0",
      },
    },
  };
}

function environmentFlag(name) {
  const value = process.env[name];
  if (value === undefined) return false;
  if (["1", "true", "yes", "on"].includes(value.toLowerCase())) return true;
  if (["0", "false", "no", "off"].includes(value.toLowerCase())) return false;
  fail(`${name} must be a boolean flag`);
}

function pushProbeEnabled() {
  return environmentFlag("TUIST_TOASTTY_MOBILE_PUSH_PROBE");
}

function validatePushProbe(command) {
  if (!pushProbeEnabled()) return;
  if (environmentFlag("TUIST_TOASTTY_MOBILE_PROD_TEST")) {
    fail("TUIST_TOASTTY_MOBILE_PUSH_PROBE cannot use prod-test identity");
  }
  for (const name of ["TOASTTY_IOS_CONFIGURATION", "TOASTTY_NATIVE_DEVICE_BUILD_CONFIGURATION"]) {
    if (process.env[name] !== undefined && process.env[name] !== "Debug") {
      fail("TUIST_TOASTTY_MOBILE_PUSH_PROBE requires Debug configuration");
    }
  }
  for (const name of ["TUIST_TOASTTY_MOBILE_BUNDLE_ID", "TOASTTY_MOBILE_BUNDLE_ID"]) {
    if (process.env[name] !== undefined && process.env[name] !== "com.giantthings.toastty.mobile.dev") {
      fail("TUIST_TOASTTY_MOBILE_PUSH_PROBE requires the fixed physical-device Debug identity");
    }
  }
  if (command !== "native-device"
    && !(command === "generate" && environmentFlag("TUIST_TOASTTY_MOBILE_PHYSICAL_DEVICE"))) {
    fail("TUIST_TOASTTY_MOBILE_PUSH_PROBE requires native-device, or generate with TUIST_TOASTTY_MOBILE_PHYSICAL_DEVICE=1");
  }
}

function validatePushRelayConfiguration(command) {
  const developmentURL = process.env.TUIST_TOASTTY_MOBILE_PUSH_RELAY_URL;
  const productionURL = process.env.TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL;
  for (const raw of [developmentURL, productionURL].filter((value) => value !== undefined)) {
    let url;
    try { url = new URL(raw); } catch { fail("Push relay must be an HTTPS origin"); }
    if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash
      || !["", "/"].includes(url.pathname) || url.port) {
      fail("Push relay must be an HTTPS origin without credentials, query, or path");
    }
  }
  if (!developmentURL && !productionURL) return;
  if (pushProbeEnabled() || environmentFlag("TUIST_TOASTTY_MOBILE_PROD_TEST")) {
    fail("Notifications cannot use the operator probe or prod-test identity");
  }
  if (developmentURL) {
    if (process.env.TUIST_TOASTTY_MOBILE_PUSH_ENVIRONMENT !== "development") {
      fail("Development notifications require explicit development environment");
    }
    for (const name of ["TUIST_TOASTTY_MOBILE_BUNDLE_ID", "TOASTTY_MOBILE_BUNDLE_ID"]) {
      if (process.env[name] !== undefined && process.env[name] !== "com.giantthings.toastty.mobile.dev") {
        fail("Development notifications require the fixed physical-device identity");
      }
    }
    if (command !== "native-device" && !environmentFlag("TUIST_TOASTTY_MOBILE_PHYSICAL_DEVICE")) {
      fail("Development notifications require the fixed physical-device identity");
    }
  }
  if (productionURL) {
    if (productionURL === developmentURL) fail("Production notifications require a separate relay origin");
    if (command === "native-device") fail("Native Debug device builds cannot configure production notifications");
    const relayID = process.env.TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_ID;
    if (process.env.TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_ENVIRONMENT !== "production"
      || !relayID || relayID === "toastty-push-dev-v1") {
      fail("Production notifications require a separate relay ID and explicit production environment");
    }
  }
}

function printHelp() {
  process.stdout.write(`Usage: node ios/scripts/toastty-ios.mjs <command> [options]\n\nCommands:\n  generate       Install Tuist packages and generate the Xcode workspace\n  build          Generate, select an iOS 18+ simulator, and build the app\n  test           Generate, select an iOS 18+ simulator, and test the native client\n  native-device  Build Debug for the fixed development identity, then install and launch it\n\nAll commands:\n  --dry-run          Print a deterministic plan without invoking tools\n\nTest options:\n  --skip-performance-budgets  Exclude the provisional domain timing/memory budget test\n                             Large-page correctness remains covered\n  --ui-tests smoke   Run app/domain tests and the two CI fixture UI tests\n  --ui-tests all     Run all app, domain, and UI tests (Debug default)\n                   UI selectors require Debug; Release runs app/domain tests without UI tests\n\nNative device options:\n  --preflight-only   Check the toolchain and selected physical iPhone, then stop\n  --build-only       Build and validate the signed app without install or launch\n  --device <value>   Select an exact CoreDevice identifier, UDID, hostname, or unique name\n\nEnvironment:\n  TUIST_TOASTTY_MOBILE_PUSH_PROBE       Opt in to the fixed-identity Debug APNs sandbox receiver\n                                     Use native-device; Release and prod-test are rejected\n  TOASTTY_IOS_CONFIGURATION             Debug or Release (default: Debug)\n  TOASTTY_IOS_DESTINATION               Explicit simulator xcodebuild destination\n  TOASTTY_IOS_SIMULATOR_DEVICE_NAMES    Preferred iPhone names, comma-separated\n  TOASTTY_IOS_RUN_ID                    Simulator run label\n  TOASTTY_IOS_RUN_ROOT                  Simulator run directory override\n  TOASTTY_IOS_DERIVED_DATA_PATH         Simulator DerivedData override\n  TOASTTY_IOS_WORKTREE_ID               Worktree identity override\n  TOASTTY_IOS_DEVELOPMENT_TEAM          Override the repository Apple development team\n  TOASTTY_NATIVE_DEVICE_RUN_ID          Physical-device run label override\n  TOASTTY_NATIVE_DEVICE_RUN_ROOT        Physical-device evidence directory override\n  TOASTTY_NATIVE_DEVICE_DERIVED_DATA_PATH Physical-device DerivedData override\n`);
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  const { command, dryRun, uiTests, skipPerformanceBudgets } = options;
  if (command === "help") {
    if (dryRun) fail("help does not accept --dry-run");
    printHelp();
    return;
  }
  if (!["generate", "build", "test", "native-device"].includes(command)) {
    printHelp();
    throw new CommandFailure(`unknown command: ${command}`);
  }

  validatePushProbe(command);
  validatePushRelayConfiguration(command);

  if (command === "test" && uiTests !== undefined
    && (process.env.TOASTTY_IOS_CONFIGURATION?.trim() || "Debug") === "Release") {
    fail("--ui-tests requires Debug configuration");
  }

  const context = commandContext(command, dryRun);
  if (command === "native-device") {
    const spec = nativeDeviceSpec(options, context);
    if (dryRun) {
      process.stdout.write(`${JSON.stringify(spec.summary, null, 2)}\n`);
      return;
    }
    runChecked(spec.executable, spec.args, { env: spec.environment });
    return;
  }
  if (dryRun) {
    process.stdout.write(`${JSON.stringify(dryRunPlan(command, context, uiTests, skipPerformanceBudgets), null, 2)}\n`);
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
    xcodebuildArguments(command, context, destination, uiTests, skipPerformanceBudgets),
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
