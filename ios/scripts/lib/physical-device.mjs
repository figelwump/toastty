#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

function deviceKeys(device) {
  return [
    device.identifier,
    device.hardwareProperties?.udid,
    device.deviceProperties?.name,
    ...(device.connectionProperties?.potentialHostnames ?? []),
  ].filter(Boolean).map(String);
}

function isPhysicalIPhone(device) {
  const hardware = device.hardwareProperties ?? {};
  return hardware.reality === "physical"
    && hardware.platform === "iOS"
    && hardware.deviceType === "iPhone";
}

export function describeDeviceListError(value) {
  if (value?.info?.outcome === "failed" || value?.error) {
    return value.error?.userInfo?.NSLocalizedDescription?.string
      ?? value.error?.message
      ?? JSON.stringify(value.error)
      ?? "unknown devicectl list devices failure";
  }
  if (!Array.isArray(value?.result?.devices)) {
    return "devicectl list devices did not include result.devices";
  }
  return null;
}

export function readinessProblems(device) {
  const pairingState = device.connectionProperties?.pairingState ?? "unknown";
  const developerModeStatus = device.deviceProperties?.developerModeStatus ?? "unknown";
  const tunnelState = device.connectionProperties?.tunnelState ?? "unknown";
  const ddiServicesAvailable = device.deviceProperties?.ddiServicesAvailable;
  const problems = [];

  if (pairingState !== "paired") problems.push(`pairingState=${pairingState}`);
  if (developerModeStatus === "disabled") {
    problems.push(`developerModeStatus=${developerModeStatus}`);
  }
  if (tunnelState !== "connected" || ddiServicesAvailable !== true) {
    problems.push(
      `device services unavailable (tunnelState=${tunnelState}, ddiServicesAvailable=${ddiServicesAvailable})`,
    );
  }
  if (!device.identifier || !device.hardwareProperties?.udid) {
    problems.push("missing device identifier or UDID");
  }
  return problems;
}

function readinessHints(problems) {
  const hints = [];
  if (problems.some((problem) => problem.startsWith("pairingState="))) {
    hints.push("Unlock the iPhone, accept Trust This Computer, or pair it in Xcode Devices and Simulators.");
  }
  if (problems.some((problem) => problem.startsWith("developerModeStatus="))) {
    hints.push("Enable Developer Mode in iPhone Settings > Privacy & Security, then reconnect it.");
  }
  if (problems.some((problem) => problem.includes("device services unavailable"))) {
    hints.push("Unlock the iPhone and reconnect USB. For Wi-Fi, enable Connect via network in Xcode Devices and Simulators.");
  }
  return [...new Set(hints)];
}

export function summarizePhysicalDevice(device) {
  const problems = readinessProblems(device);
  return {
    name: device.deviceProperties?.name ?? "Unknown iPhone",
    identifier: device.identifier ?? "",
    udid: device.hardwareProperties?.udid ?? "",
    osVersion: device.deviceProperties?.osVersionNumber ?? "unknown",
    tunnelState: device.connectionProperties?.tunnelState ?? "unknown",
    pairingState: device.connectionProperties?.pairingState ?? "unknown",
    developerModeStatus: device.deviceProperties?.developerModeStatus ?? "unknown",
    ddiServicesAvailable: device.deviceProperties?.ddiServicesAvailable,
    potentialHostnames: device.connectionProperties?.potentialHostnames ?? [],
    readinessProblems: problems,
    readinessHints: readinessHints(problems),
  };
}

export function selectPhysicalDevice(value, requested = "") {
  const deviceListError = describeDeviceListError(value);
  const devices = Array.isArray(value?.result?.devices) ? value.result.devices : [];
  const candidates = devices.filter(isPhysicalIPhone);
  const requestedValue = requested.trim();

  if (deviceListError) {
    return {
      ok: false,
      error: `devicectl did not return a usable physical device list: ${deviceListError}`,
      deviceListError,
      requestedDevice: requestedValue || undefined,
      candidateDevices: candidates.map(summarizePhysicalDevice),
    };
  }

  let selected;
  if (requestedValue) {
    const matches = candidates.filter((device) => deviceKeys(device).includes(requestedValue));
    if (matches.length === 0) {
      return {
        ok: false,
        error: `No physical iPhone matched --device ${requestedValue}`,
        requestedDevice: requestedValue,
        candidateDevices: candidates.map(summarizePhysicalDevice),
      };
    }
    if (matches.length > 1) {
      return {
        ok: false,
        error: `--device ${requestedValue} matched multiple iPhones; use a CoreDevice identifier or UDID`,
        requestedDevice: requestedValue,
        candidateDevices: matches.map(summarizePhysicalDevice),
      };
    }
    selected = matches[0];
  } else {
    const ready = candidates.filter((device) => readinessProblems(device).length === 0);
    if (ready.length === 0) {
      return {
        ok: false,
        error: candidates.length === 0
          ? "No physical iPhone is paired with this Mac"
          : "No ready physical iPhone is available",
        candidateDevices: candidates.map(summarizePhysicalDevice),
      };
    }
    if (ready.length > 1) {
      return {
        ok: false,
        error: "Multiple ready iPhones are available; pass --device with an identifier, UDID, hostname, or unique name",
        candidateDevices: ready.map(summarizePhysicalDevice),
      };
    }
    selected = ready[0];
  }

  const summary = summarizePhysicalDevice(selected);
  if (summary.readinessProblems.length > 0) {
    return {
      ok: false,
      error: `Selected iPhone is not ready: ${summary.readinessProblems.join("; ")}`,
      requestedDevice: requestedValue || undefined,
      candidateDevices: [summary],
    };
  }
  return { ok: true, selectedDevice: summary };
}

export function warmConnectTargets(value, requested = "") {
  if (describeDeviceListError(value)) return [];
  const requestedValue = requested.trim();
  return value.result.devices
    .filter(isPhysicalIPhone)
    .filter((device) => !requestedValue || deviceKeys(device).includes(requestedValue))
    .filter((device) => {
      const paired = device.connectionProperties?.pairingState === "paired";
      const developerMode = device.deviceProperties?.developerModeStatus;
      return paired
        && developerMode !== "disabled"
        && Boolean(device.identifier)
        && Boolean(device.hardwareProperties?.udid)
        && readinessProblems(device).some((problem) => problem.includes("device services unavailable"));
    })
    .map((device) => ({
      identifier: String(device.identifier),
      name: String(device.deviceProperties?.name ?? "Unknown iPhone"),
    }));
}

export function destinationIsAvailable(value, udid) {
  let inAvailableSection = false;
  for (const line of String(value).split("\n")) {
    if (line.includes("Available destinations")) {
      inAvailableSection = true;
      continue;
    }
    if (line.includes("Ineligible destinations")) {
      inAvailableSection = false;
      continue;
    }
    if (!inAvailableSection) continue;
    const fields = line
      .replace(/[{}]/g, "")
      .split(",")
      .map((field) => field.trim());
    if (fields.includes(`id:${udid}`)) return true;
  }
  return false;
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const options = { command };
  for (let index = 0; index < rest.length; index += 1) {
    const argument = rest[index];
    if (argument === "--probe") {
      options.probe = true;
      continue;
    }
    if (!argument.startsWith("--")) throw new Error(`Unexpected argument: ${argument}`);
    const value = rest[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`${argument} requires a value`);
    options[argument.slice(2)] = value;
    index += 1;
  }
  return options;
}

function readDeviceList(inputPath) {
  return JSON.parse(readFileSync(inputPath, "utf8"));
}

function printSelectionError(report) {
  console.error(report.error);
  for (const device of report.candidateDevices ?? []) {
    const status = device.readinessProblems.length > 0
      ? device.readinessProblems.join("; ")
      : "ready";
    console.error(`- ${device.name} (${device.udid || device.identifier || "unknown"}): ${status}`);
    for (const hint of device.readinessHints ?? []) console.error(`  ${hint}`);
  }
}

function main(argv) {
  const options = parseArgs(argv);
  if (!options.input) throw new Error("--input is required");
  if (options.command === "validate-destination") {
    if (!options.udid) throw new Error("--udid is required");
    if (!destinationIsAvailable(readFileSync(options.input, "utf8"), options.udid)) {
      throw new Error(`physical iPhone ${options.udid} is not an available Xcode destination`);
    }
    return;
  }
  const value = readDeviceList(options.input);

  switch (options.command) {
    case "validate-list": {
      const error = describeDeviceListError(value);
      if (error) throw new Error(error);
      return;
    }
    case "warm-targets":
      for (const target of warmConnectTargets(value, options.requested ?? "")) {
        process.stdout.write(`${target.identifier}\t${target.name.replaceAll("\t", " ")}\n`);
      }
      return;
    case "select": {
      if (!options.output) throw new Error("--output is required");
      const report = selectPhysicalDevice(value, options.requested ?? "");
      writeFileSync(options.output, `${JSON.stringify({
        ...report,
        selectedAt: new Date().toISOString(),
      }, null, 2)}\n`);
      if (!report.ok) {
        if (!options.probe) printSelectionError(report);
        process.exitCode = 2;
        return;
      }
      const device = report.selectedDevice;
      process.stdout.write([
        device.identifier,
        device.udid,
        device.name.replaceAll("\t", " "),
        device.osVersion,
      ].join("\t"));
      return;
    }
    default:
      throw new Error("Expected validate-destination, validate-list, warm-targets, or select command");
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
