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

test("push probe requires its compiled receiver and development APNs entitlements in both signatures", () => {
  const probeExpected = { ...expected, pushProbe: true };
  assert.throws(() => validateBuildSettings(settings(), probeExpected), /compilation condition is missing/);
  validateBuildSettings(settings({
    SWIFT_ACTIVE_COMPILATION_CONDITIONS: "DEBUG TOASTTY_MOBILE_PUSH_PROBE",
  }), probeExpected);
  assert.throws(() => validateBuildSettings(settings({
    SWIFT_ACTIVE_COMPILATION_CONDITIONS: "DEBUG TOASTTY_MOBILE_PUSH_PROBE",
  }), { ...expected, pushProbe: false }), /present in a normal Debug build/);

  for (const apsEnvironment of [undefined, "production", "development"]) {
    const entitlements = {
      ...profile().Entitlements,
      ...(apsEnvironment === undefined ? {} : { "aps-environment": apsEnvironment }),
    };
    const validateProfile = () => validateDevelopmentProfile(profile({ Entitlements: entitlements }), probeExpected);
    const validateSignature = () => validateSignedEntitlements(entitlements, probeExpected);
    if (apsEnvironment === "development") {
      validateProfile();
      validateSignature();
    } else {
      assert.throws(validateProfile, /provisioning aps-environment mismatch/);
      assert.throws(validateSignature, /signed aps-environment mismatch/);
    }
    // Existing device builds do not require or reject an unrelated push entitlement.
    validateDevelopmentProfile(profile({ Entitlements: entitlements }), expected);
    validateSignedEntitlements(entitlements, expected);
  }
});

test("validator CLI parses real plist Date and Data values without forwarding certificate data", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "toastty-build-validator-"));
  const bin = path.join(root, "bin");
  const appPath = path.join(root, "Debug-iphoneos", "Toastty.app");
  mkdirSync(bin, { recursive: true });
  mkdirSync(appPath, { recursive: true });
  const plist = (body) => `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>${body}</dict></plist>`;
  const identityEntitlements = `
    <key>application-identifier</key><string>${expected.team}.${expected.bundleID}</string>
    <key>com.apple.developer.team-identifier</key><string>${expected.team}</string>
    <key>get-task-allow</key><true/>
    <key>aps-environment</key><string>development</string>`;
  writeFileSync(path.join(appPath, "Info.plist"), plist(`
    <key>CFBundleIdentifier</key><string>${expected.bundleID}</string>
    <key>CFBundleDisplayName</key><string>${expected.displayName}</string>
    <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key>
    <array><string>${expected.urlScheme}</string></array></dict></array>`));
  writeFileSync(path.join(appPath, "embedded.mobileprovision"), "stub-cms");

  const settingsPath = path.join(root, "settings.json");
  writeFileSync(settingsPath, JSON.stringify(settings({
    TARGET_BUILD_DIR: path.dirname(appPath),
    FULL_PRODUCT_NAME: path.basename(appPath),
    SWIFT_ACTIVE_COMPILATION_CONDITIONS: "DEBUG TOASTTY_MOBILE_PUSH_PROBE",
  })));

  const securityStub = `#!${process.execPath}
process.stdout.write(process.env.STUB_PROFILE);
`;
  const codesignStub = `#!${process.execPath}
if (process.argv.includes("--verify")) process.exit(0);
process.stdout.write(process.env.STUB_ENTITLEMENTS);
`;
  writeFileSync(path.join(bin, "security"), securityStub, { mode: 0o755 });
  writeFileSync(path.join(bin, "codesign"), codesignStub, { mode: 0o755 });

  for (const [expiration, device, enterprise, error] of [
    ["2099-01-01T00:00:00Z", expected.deviceUDID, false, null],
    ["2020-01-01T00:00:00Z", expected.deviceUDID, false, /expired/],
    ["2099-01-01T00:00:00Z", "OTHER-DEVICE", false, /does not include device/],
    ["2099-01-01T00:00:00Z", expected.deviceUDID, true, /enterprise profile/],
    [null, expected.deviceUDID, false, /invalid expiration/],
    ["malformed", expected.deviceUDID, false, /could not be decoded/],
  ]) {
    const result = spawnSync(process.execPath, [
      validatorPath,
      "--settings", settingsPath,
      "--bundle-id", expected.bundleID,
      "--device-udid", expected.deviceUDID,
      "--display-name", expected.displayName,
      "--team", expected.team,
      "--url-scheme", expected.urlScheme,
      "--push-probe", "1",
    ], {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        STUB_PROFILE: expiration === "malformed" ? "not a plist" : plist(`
          <key>TeamIdentifier</key><array><string>${expected.team}</string></array>
          <key>ProvisionedDevices</key><array><string>${device}</string></array>
          <key>ProvisionsAllDevices</key><${enterprise ? "true" : "false"}/>
          ${expiration === null ? "" : `<key>ExpirationDate</key><date>${expiration}</date>`}
          <key>DeveloperCertificates</key><array><data>AQID</data></array>
          <key>Entitlements</key><dict>${identityEntitlements}</dict>`),
        STUB_ENTITLEMENTS: plist(identityEntitlements),
      },
    });
    if (error) {
      assert.equal(result.status, 1);
      assert.match(result.stderr, error);
      assert.equal(result.stdout, "");
    } else {
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout, appPath);
    }
    assert.doesNotMatch(result.stderr + result.stdout, /DeveloperCertificates|AQID|import plistlib/);
  }
});
