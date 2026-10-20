#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  closeSync, constants, fchmodSync, fstatSync, fsyncSync, mkdirSync,
  mkdtempSync, openSync, readSync, renameSync, rmSync, writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";

const diagnosticsDirectory = "Library/Application Support/ToasttyDiagnostics";
const maximumBytes = 256 * 1024;
const futureSkewMilliseconds = 60_000;
const usage = `Usage: node ios/scripts/collect-diagnostics.mjs --device <identifier> --bundle-id <bundleID> --output <file.json>
  [--previous] [--expected-build <build>] [--max-age-seconds <0..31536000>] [--dry-run]

Copies a saved app report from an explicitly selected physical iPhone.
This does not launch, install, or change the app. A suspended app can have an old snapshot.
The default accepts old snapshots and prints their age. --max-age-seconds requires freshness.
`;

class CollectorError extends Error {}

function fail(message) {
  throw new CollectorError(message);
}

function parseArguments(argv) {
  const options = {};
  const valuedFlags = new Set([
    "--device", "--bundle-id", "--output", "--expected-build", "--max-age-seconds",
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === "--help" && argv.length === 1) return { help: true };
    if ((flag === "--dry-run" || flag === "--previous") && !options[flag]) {
      options[flag] = true;
    } else if (valuedFlags.has(flag) && options[flag] === undefined) {
      const value = argv[index + 1];
      if (!value?.trim() || value.startsWith("--") || /[\x00-\x1f\x7f]/.test(value)) {
        fail(`${flag} requires a value without control characters`);
      }
      options[flag] = value;
      index += 1;
    } else {
      fail("Unknown or repeated argument; use --help for usage");
    }
  }
  for (const flag of ["--device", "--bundle-id", "--output"]) {
    if (!options[flag]) fail(`${flag} is required`);
  }
  if (options["--device"].length > 256) fail("--device is too long");
  if (!/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(options["--bundle-id"])) {
    fail("--bundle-id must be an app bundle identifier");
  }
  if (options["--expected-build"]?.length > 128) fail("--expected-build is too long");
  if (options["--max-age-seconds"] !== undefined) {
    const value = options["--max-age-seconds"];
    const seconds = Number(value);
    if (!/^\d+(?:\.\d+)?$/.test(value) || !Number.isFinite(seconds)
      || seconds < 0 || seconds > 31_536_000) {
      fail("--max-age-seconds must be finite seconds from 0 through 31536000");
    }
    options.maximumAgeMilliseconds = seconds * 1000;
  }
  return options;
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function timestamp(value) {
  if (typeof value !== "string") return NaN;
  const parts = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|([+-])(\d{2}):(\d{2}))$/.exec(value);
  if (!parts) return NaN;
  const [, year, month, day, hour, minute, second, , offsetHour, offsetMinute] = parts;
  const daysInMonth = new Date(Date.UTC(Number(year), Number(month), 0)).getUTCDate();
  if (Number(month) < 1 || Number(month) > 12 || Number(day) < 1
    || Number(day) > daysInMonth || Number(hour) > 23 || Number(minute) > 59
    || Number(second) > 59 || Number(offsetHour ?? 0) > 23 || Number(offsetMinute ?? 0) > 59) {
    return NaN;
  }
  return Date.parse(value);
}

function validateReport(report, options, now) {
  if (!isObject(report) || report.schemaVersion !== 1 || !isObject(report.app)
    || ![report.app.bundleID, report.app.version, report.app.build].every(
      (value) => typeof value === "string" && value.trim().length > 0 && value.length <= 256,
    )
    || typeof report.runID !== "string"
    || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(report.runID)
    || !Array.isArray(report.events) || report.events.length > 128
    || !report.events.every((entry) => isObject(entry)
      && Number.isSafeInteger(entry.sequence) && entry.sequence >= 0
      && Number.isFinite(timestamp(entry.recordedAt))
      && typeof entry.event === "string" && /^[A-Za-z0-9_.-]{1,128}$/.test(entry.event)
      && (entry.pushDetails === undefined || isObject(entry.pushDetails)))
    || (report.push !== undefined && !isObject(report.push))) {
    fail("Report has an unsupported or malformed diagnostics schema");
  }
  const started = timestamp(report.runStartedAt);
  const captured = timestamp(report.capturedAt);
  if (!Number.isFinite(started) || !Number.isFinite(captured) || started > captured) {
    fail("Report has invalid or out-of-order run and capture timestamps");
  }
  if (captured > now + futureSkewMilliseconds) {
    fail("Report capture time is more than 60 seconds in the future; check device clocks");
  }
  if (report.app.bundleID !== options["--bundle-id"]) fail("Report bundle ID does not match --bundle-id");
  if (options["--expected-build"] !== undefined && report.app.build !== options["--expected-build"]) {
    fail("Report build does not match --expected-build");
  }
  const age = Math.max(0, now - captured);
  if (options.maximumAgeMilliseconds !== undefined && age > options.maximumAgeMilliseconds) {
    fail("Report snapshot is older than --max-age-seconds");
  }
  return { captured, age, clockAheadMilliseconds: Math.max(0, captured - now) };
}

function printPushSummary(push, captured) {
  if (!isObject(push)) return;
  const lines = [];
  for (const [key, label] of [
    ["stage", "stage"], ["permission", "permission"],
    ["lastAction", "last action"], ["lastReturnReason", "last return reason"],
  ]) {
    if (typeof push[key] === "string" && /^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(push[key])) {
      lines.push(`  ${label}: ${push[key]}`);
    }
  }
  for (const [key, label] of [
    ["reconciling", "reconciling"], ["activeRegistrationEnabled", "active registration enabled"],
  ]) {
    if (typeof push[key] === "boolean") lines.push(`  ${label}: ${push[key]}`);
  }
  for (const [key, label, cooldown] of [
    ["lastReturnAt", "last return time", false],
    ["cooldownUntil", "cooldown until", true],
    ["savedCooldownUntil", "saved cooldown until", true],
    ["retryScheduledAt", "retry scheduled at", false],
  ]) {
    const date = timestamp(push[key]);
    if (!Number.isFinite(date)) continue;
    const remaining = cooldown
      ? `; remaining at capture: ${(Math.max(0, date - captured) / 1000).toFixed(1)} seconds`
      : "";
    lines.push(`  ${label}: ${new Date(date).toISOString()}${remaining}`);
  }
  if (lines.length > 0) {
    process.stdout.write(`Push snapshot (frozen observation at capture, not current live state):\n${lines.join("\n")}\n`);
  }
}

function removeTemporaryDirectory(directory) {
  try {
    rmSync(directory, { recursive: true, force: true });
  } catch {
    process.stderr.write("[collect-diagnostics] Could not remove a private temporary diagnostics directory.\n");
  }
}

function readReport(filename) {
  let descriptor;
  try {
    descriptor = openSync(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
    const info = fstatSync(descriptor);
    if (!info.isFile() || info.size > maximumBytes) fail("Copied report must be a regular file no larger than 256 KiB");
    const buffer = Buffer.alloc(maximumBytes + 1);
    let length = 0;
    while (length < buffer.length) {
      const count = readSync(descriptor, buffer, length, buffer.length - length, null);
      if (count === 0) break;
      length += count;
    }
    const bytes = buffer.subarray(0, length);
    if (bytes.length > maximumBytes) fail("Copied report exceeds 256 KiB");
    try {
      return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    } catch {
      fail("Copied report is not valid JSON");
    }
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

function saveReport(destination, bytes) {
  const directory = path.dirname(path.resolve(destination));
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const temporaryDirectory = mkdtempSync(path.join(directory, ".toastty-diagnostics-"));
  const staged = path.join(temporaryDirectory, "report.json");
  let descriptor;
  try {
    descriptor = openSync(staged, "wx", 0o600);
    fchmodSync(descriptor, 0o600);
    writeFileSync(descriptor, bytes);
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(staged, path.resolve(destination));
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
    removeTemporaryDirectory(temporaryDirectory);
  }
}

let saved = false;

function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(usage);
    return;
  }
  const copyArguments = (destination) => [
    "devicectl", "device", "copy", "from", "--device", options["--device"],
    "--domain-type", "appDataContainer", "--domain-identifier", options["--bundle-id"],
    "--source", `${diagnosticsDirectory}/${options["--previous"] ? "previous" : "current"}.json`,
    "--destination", destination, "--timeout", "30",
  ];
  if (options["--dry-run"]) {
    process.stdout.write(`Read-only command: xcrun ${copyArguments("<fresh temporary file>").map((value) => JSON.stringify(value)).join(" ")}\n`);
    process.stdout.write("Dry run: no device command ran and no report was saved.\n");
    return;
  }
  const temporaryDirectory = mkdtempSync(path.join(os.tmpdir(), "toastty-ios-diagnostics-"));
  try {
    const copied = path.join(temporaryDirectory, "report.json");
    const result = spawnSync("xcrun", copyArguments(copied), {
      stdio: "ignore", timeout: 35_000,
    });
    if (result.error || result.status !== 0) {
      const detail = result.error?.code === "ETIMEDOUT" ? "timed out"
        : Number.isInteger(result.status) ? `exited with status ${result.status}`
          : typeof result.signal === "string" && /^SIG[A-Z0-9]+$/.test(result.signal)
            ? `ended with signal ${result.signal}` : "could not start";
      fail(`Device report copy failed (${detail}); check the selected device, pairing, app installation, and saved report`);
    }
    let capture;
    try {
      capture = readReport(copied);
    } catch (error) {
      if (!(error instanceof CollectorError)) fail("Device copy did not produce a readable regular report file");
      throw error;
    }
    const { captured, age, clockAheadMilliseconds } = validateReport(capture, options, Date.now());
    // Save the parsed document so duplicate keys cannot disagree with the validated values.
    const bytes = Buffer.from(JSON.stringify(capture));
    if (bytes.length > maximumBytes) fail("Validated report exceeds 256 KiB");
    saveReport(options["--output"], bytes);
    saved = true;
    process.stdout.write(`Saved diagnostics to ${path.resolve(options["--output"])}\n`);
    process.stdout.write(`Snapshot time: ${new Date(captured).toISOString()}; age: ${(age / 1000).toFixed(1)} seconds.\n`);
    if (clockAheadMilliseconds > 0) {
      process.stdout.write(`Device clock is ahead by ${(clockAheadMilliseconds / 1000).toFixed(1)} seconds; displayed age is clamped to zero.\n`);
    }
    printPushSummary(capture.push, captured);
    process.stdout.write("This is a saved capture, not live proof. A suspended app can have an old snapshot.\n");
  } finally {
    removeTemporaryDirectory(temporaryDirectory);
  }
}

try {
  main();
} catch (error) {
  // Only messages created by this collector can reach the terminal.
  const message = error instanceof CollectorError ? error.message : "Could not complete diagnostics collection";
  const outcome = saved ? "The validated report was saved before this error."
    : "No new report was saved; any existing output is unchanged.";
  process.stderr.write(`[collect-diagnostics] ${message}. ${outcome}\n`);
  process.exitCode = 1;
}
