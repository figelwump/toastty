import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  validateAppInfo,
  validateBuildSettings,
  validateDevelopmentProfile,
  validateSignedEntitlements,
} from "../../scripts/lib/validate-device-build.mjs";

const testPath = fileURLToPath(import.meta.url);
const validatorPath = path.resolve(
  path.dirname(testPath),
  "../../scripts/lib/validate-device-build.mjs",
);

const expected = {
  bundleID: "com.giantthings.toastty.mobile.dev",
  deviceUDID: "DEVICE-UDID",
  displayName: "Toastty Dev",
  team: "TEAM123456",
  urlScheme: "toastty-mobile-dev",
};

function settings(overrides = {}) {
  return [{
    target: "ToasttyMobileApp",
    buildSettings: {
      CONFIGURATION: "Debug",
      PRODUCT_BUNDLE_IDENTIFIER: expected.bundleID,
      DEVELOPMENT_TEAM: expected.team,
      CODE_SIGN_STYLE: "Automatic",
      TOASTTY_MOBILE_APP_DISPLAY_NAME: expected.displayName,
      TOASTTY_MOBILE_URL_SCHEME: expected.urlScheme,
      TARGET_BUILD_DIR: "/tmp/Derived/Build/Products/Debug-iphoneos",
      FULL_PRODUCT_NAME: "Toastty.app",
      ...overrides,
    },
  }];
}

function profile(overrides = {}) {
  return {
    TeamIdentifier: [expected.team],
    ExpirationDate: "2099-01-01T00:00:00Z",
    ProvisionedDevices: [expected.deviceUDID],
    ProvisionsAllDevices: false,
    Entitlements: {
      "application-identifier": `${expected.team}.${expected.bundleID}`,
      "com.apple.developer.team-identifier": expected.team,
      "get-task-allow": true,
    },
    ...overrides,
  };
}

test("Debug build settings resolve the fixed physical-device app path", () => {
  assert.equal(
    validateBuildSettings(settings(), expected),
    "/tmp/Derived/Build/Products/Debug-iphoneos/Toastty.app",
  );
});

test("build settings reject a simulator-style bundle identity or non-Debug build", () => {
  assert.throws(
    () => validateBuildSettings(settings({
      PRODUCT_BUNDLE_IDENTIFIER: "com.giantthings.toastty.mobile.dev.worktree",
    }), expected),
    /PRODUCT_BUNDLE_IDENTIFIER mismatch/,
  );
  assert.throws(
    () => validateBuildSettings(settings({ CONFIGURATION: "Release" }), expected),
    /CONFIGURATION mismatch/,
  );
  assert.throws(
    () => validateBuildSettings([{ ...settings()[0], target: "DifferentTarget" }], expected),
    /did not return ToasttyMobileApp build settings/,
  );
});

test("Info.plist validation requires the fixed identity, display name, and dev URL scheme", () => {
  const info = {
    CFBundleIdentifier: expected.bundleID,
    CFBundleDisplayName: expected.displayName,
    CFBundleURLTypes: [{ CFBundleURLSchemes: [expected.urlScheme] }],
  };
  validateAppInfo(info, expected);
  assert.throws(
    () => validateAppInfo({ ...info, CFBundleURLTypes: [] }, expected),
    /CFBundleURLSchemes/,
  );
});

test("development profile must be team-bound, device-bound, unexpired, and debuggable", () => {
  validateDevelopmentProfile(profile(), expected);
  assert.throws(
    () => validateDevelopmentProfile(profile({ ProvisionedDevices: ["OTHER"] }), expected),
    /does not include device/,
  );
  assert.throws(
    () => validateDevelopmentProfile(profile({ ExpirationDate: "2020-01-01T00:00:00Z" }), expected),
    /expired/,
  );
  assert.throws(
    () => validateDevelopmentProfile(profile({ ProvisionsAllDevices: true }), expected),
    /enterprise profile/,
  );
  assert.throws(
    () => validateDevelopmentProfile(profile({
      Entitlements: {
        ...profile().Entitlements,
        "get-task-allow": false,
      },
    }), expected),
    /get-task-allow mismatch/,
  );
  assert.throws(
    () => validateDevelopmentProfile(profile({
      Entitlements: {
        ...profile().Entitlements,
        "application-identifier": `${expected.team}.*`,
      },
    }), expected),
    /application-identifier mismatch/,
  );
  assert.throws(
    () => validateDevelopmentProfile(profile({
      ExpirationDate: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
    }), expected),
    /expired or has an invalid expiration/,
  );
});

test("signed entitlement parsing rejects a differently signed app", () => {
  const valid = {
    "application-identifier": `${expected.team}.${expected.bundleID}`,
    "com.apple.developer.team-identifier": expected.team,
    "get-task-allow": true,
  };
  validateSignedEntitlements(valid, expected);
  assert.throws(
    () => validateSignedEntitlements({
      ...valid,
      "application-identifier": `${expected.team}.com.example.wrong`,
    }, expected),
    /signed application-identifier mismatch/,
  );
  assert.throws(
    () => validateSignedEntitlements(null, expected),
    /did not decode to a dictionary/,
  );
});

test("validator CLI consumes plist output and verifies the signed app with PATH stubs", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "toastty-build-validator-"));
  const bin = path.join(root, "bin");
  const appPath = path.join(root, "Debug-iphoneos", "Toastty.app");
  mkdirSync(bin, { recursive: true });
  mkdirSync(appPath, { recursive: true });
  writeFileSync(path.join(appPath, "Info.plist"), "stub-info");
  writeFileSync(path.join(appPath, "embedded.mobileprovision"), "stub-profile");

  const settingsPath = path.join(root, "settings.json");
  writeFileSync(settingsPath, JSON.stringify(settings({
    TARGET_BUILD_DIR: path.dirname(appPath),
    FULL_PRODUCT_NAME: path.basename(appPath),
  })));

  const plistStub = `#!${process.execPath}
const fs = require("node:fs");
const args = process.argv.slice(2);
const input = fs.readFileSync(0, "utf8");
if (args.at(-1) !== "-") {
  process.stdout.write(process.env.STUB_INFO);
} else if (input === "PROFILE_PLIST") {
  process.stdout.write(process.env.STUB_PROFILE);
} else if (input === "ENTITLEMENTS_PLIST") {
  process.stdout.write(process.env.STUB_ENTITLEMENTS);
} else {
  process.exit(9);
}
`;
  const securityStub = `#!${process.execPath}\nprocess.stdout.write("PROFILE_PLIST");\n`;
  const codesignStub = `#!${process.execPath}
if (process.argv.includes("--verify")) process.exit(0);
process.stdout.write("ENTITLEMENTS_PLIST");
`;
  writeFileSync(path.join(bin, "plutil"), plistStub, { mode: 0o755 });
  writeFileSync(path.join(bin, "security"), securityStub, { mode: 0o755 });
  writeFileSync(path.join(bin, "codesign"), codesignStub, { mode: 0o755 });

  const result = spawnSync(process.execPath, [
    validatorPath,
    "--settings", settingsPath,
    "--bundle-id", expected.bundleID,
    "--device-udid", expected.deviceUDID,
    "--display-name", expected.displayName,
    "--team", expected.team,
    "--url-scheme", expected.urlScheme,
  ], {
    encoding: "utf8",
    env: {
      ...process.env,
      PATH: bin,
      STUB_INFO: JSON.stringify({
        CFBundleIdentifier: expected.bundleID,
        CFBundleDisplayName: expected.displayName,
        CFBundleURLTypes: [{ CFBundleURLSchemes: [expected.urlScheme] }],
      }),
      STUB_PROFILE: JSON.stringify(profile()),
      STUB_ENTITLEMENTS: JSON.stringify({
        "application-identifier": `${expected.team}.${expected.bundleID}`,
        "com.apple.developer.team-identifier": expected.team,
        "get-task-allow": true,
      }),
    },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, appPath);
});
