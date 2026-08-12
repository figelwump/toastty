#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  existsSync,
  readFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--")) throw new Error(`Unexpected argument: ${argument}`);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`${argument} requires a value`);
    options[argument.slice(2)] = value;
    index += 1;
  }
  return options;
}

function requireOption(options, name) {
  const value = options[name]?.trim();
  if (!value) throw new Error(`--${name} is required`);
  return value;
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: options.encoding ?? "utf8",
    input: options.input,
  });
  if (result.error) throw new Error(`Failed to run ${command}: ${result.error.message}`);
  if (result.status !== 0) {
    const detail = String(result.stderr || result.stdout || "").trim();
    throw new Error(`${command} ${args.join(" ")} failed${detail ? `: ${detail}` : ""}`);
  }
  return result.stdout;
}

function plistFileJSON(plistPath) {
  return JSON.parse(run("plutil", ["-convert", "json", "-o", "-", plistPath]));
}

function plistDataJSON(data, label) {
  const raw = run("plutil", ["-convert", "json", "-o", "-", "-"], {
    input: data,
  });
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(`${label} did not decode to JSON: ${error.message}`);
  }
}

function requireEqual(label, actual, expected) {
  if (actual !== expected) {
    throw new Error(
      `${label} mismatch: expected ${JSON.stringify(expected)}, found ${JSON.stringify(actual)}`,
    );
  }
}

export function validateBuildSettings(value, expected) {
  const entries = Array.isArray(value) ? value : [];
  const entry = entries.find((candidate) => candidate?.target === "ToasttyMobileApp");
  const settings = entry?.buildSettings;
  if (!settings || typeof settings !== "object") {
    throw new Error("xcodebuild did not return ToasttyMobileApp build settings");
  }

  requireEqual("CONFIGURATION", settings.CONFIGURATION, "Debug");
  requireEqual("PRODUCT_BUNDLE_IDENTIFIER", settings.PRODUCT_BUNDLE_IDENTIFIER, expected.bundleID);
  requireEqual("DEVELOPMENT_TEAM", settings.DEVELOPMENT_TEAM, expected.team);
  requireEqual("CODE_SIGN_STYLE", settings.CODE_SIGN_STYLE, "Automatic");
  requireEqual("TOASTTY_MOBILE_APP_DISPLAY_NAME", settings.TOASTTY_MOBILE_APP_DISPLAY_NAME, expected.displayName);
  requireEqual("TOASTTY_MOBILE_URL_SCHEME", settings.TOASTTY_MOBILE_URL_SCHEME, expected.urlScheme);

  if (!settings.TARGET_BUILD_DIR || !settings.FULL_PRODUCT_NAME) {
    throw new Error("xcodebuild settings are missing TARGET_BUILD_DIR or FULL_PRODUCT_NAME");
  }
  return path.join(settings.TARGET_BUILD_DIR, settings.FULL_PRODUCT_NAME);
}

export function validateAppInfo(info, expected) {
  requireEqual("CFBundleIdentifier", info.CFBundleIdentifier, expected.bundleID);
  requireEqual("CFBundleDisplayName", info.CFBundleDisplayName, expected.displayName);
  const schemes = (info.CFBundleURLTypes ?? [])
    .flatMap((entry) => entry?.CFBundleURLSchemes ?? [])
    .filter((value) => typeof value === "string");
  if (!schemes.includes(expected.urlScheme)) {
    throw new Error(`CFBundleURLSchemes does not include ${expected.urlScheme}`);
  }
}

export function validateDevelopmentProfile(profile, expected) {
  const teams = Array.isArray(profile.TeamIdentifier) ? profile.TeamIdentifier : [];
  if (!teams.includes(expected.team)) {
    throw new Error(
      `Provisioning profile team mismatch: expected ${expected.team}, found ${teams.join(", ") || "none"}`,
    );
  }

  const entitlements = profile.Entitlements ?? {};
  const profileApplicationID = entitlements["application-identifier"];
  const expectedApplicationID = `${expected.team}.${expected.bundleID}`;
  if (profileApplicationID !== expectedApplicationID) {
    throw new Error(
      `provisioning application-identifier mismatch: expected ${JSON.stringify(expectedApplicationID)}, found ${JSON.stringify(profileApplicationID)}`,
    );
  }
  requireEqual(
    "provisioning com.apple.developer.team-identifier",
    entitlements["com.apple.developer.team-identifier"],
    expected.team,
  );
  requireEqual("provisioning get-task-allow", entitlements["get-task-allow"], true);

  const devices = Array.isArray(profile.ProvisionedDevices) ? profile.ProvisionedDevices : [];
  if (!devices.includes(expected.deviceUDID)) {
    throw new Error(`Provisioning profile does not include device ${expected.deviceUDID}`);
  }
  if (profile.ProvisionsAllDevices === true) {
    throw new Error("Provisioning profile is an enterprise profile, not an iOS development profile");
  }

  const expiration = Date.parse(profile.ExpirationDate);
  const minimumValidityMilliseconds = 24 * 60 * 60 * 1000;
  if (!Number.isFinite(expiration) || expiration <= Date.now() + minimumValidityMilliseconds) {
    throw new Error(`Provisioning profile is expired or has an invalid expiration: ${profile.ExpirationDate}`);
  }
}

export function validateSignedEntitlements(entitlements, expected) {
  if (!entitlements || typeof entitlements !== "object" || Array.isArray(entitlements)) {
    throw new Error("signed entitlements did not decode to a dictionary");
  }
  requireEqual(
    "signed application-identifier",
    entitlements["application-identifier"],
    `${expected.team}.${expected.bundleID}`,
  );
  requireEqual(
    "signed com.apple.developer.team-identifier",
    entitlements["com.apple.developer.team-identifier"],
    expected.team,
  );
  requireEqual("signed get-task-allow", entitlements["get-task-allow"], true);
}

function main(argv) {
  const options = parseArgs(argv);
  const settingsPath = requireOption(options, "settings");
  const expected = {
    bundleID: requireOption(options, "bundle-id"),
    deviceUDID: requireOption(options, "device-udid"),
    displayName: requireOption(options, "display-name"),
    team: requireOption(options, "team"),
    urlScheme: requireOption(options, "url-scheme"),
  };

  const appPath = validateBuildSettings(
    JSON.parse(readFileSync(settingsPath, "utf8")),
    expected,
  );
  if (!existsSync(appPath)) throw new Error(`Built app does not exist at ${appPath}`);

  const infoPath = path.join(appPath, "Info.plist");
  const profilePath = path.join(appPath, "embedded.mobileprovision");
  if (!existsSync(infoPath)) throw new Error(`Built app Info.plist is missing at ${infoPath}`);
  if (!existsSync(profilePath)) {
    throw new Error(`Built app development provisioning profile is missing at ${profilePath}`);
  }

  validateAppInfo(plistFileJSON(infoPath), expected);
  const decodedProfile = run("security", ["cms", "-D", "-i", profilePath], { encoding: null });
  validateDevelopmentProfile(plistDataJSON(decodedProfile, "provisioning profile"), expected);
  run("codesign", ["--verify", "--deep", "--strict", appPath]);
  const signedEntitlements = run(
    "codesign",
    ["-d", "--entitlements", ":-", appPath],
  );
  validateSignedEntitlements(
    plistDataJSON(signedEntitlements, "signed entitlements"),
    expected,
  );

  process.stdout.write(appPath);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
