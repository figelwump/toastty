import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "../../..");
const releaseScript = path.join(repositoryRoot, "scripts/ci/ios-testflight.sh");
const projectManifest = path.join(repositoryRoot, "ios/Project.swift");
const workflowPath = path.join(repositoryRoot, ".github/workflows/ios-testflight.yml");
const mobileWorkflowPath = path.join(repositoryRoot, ".github/workflows/mobile-ios.yml");
const secretsManifest = path.join(repositoryRoot, ".secrets");
const iconSetDirectory = path.join(
  repositoryRoot,
  "ios/Resources/ToasttyMobileApp/Assets.xcassets/AppIcon.appiconset",
);

function read(relativePath) {
  return fs.readFileSync(path.join(repositoryRoot, relativePath), "utf8");
}

function writeExecutable(directory, name, contents) {
  const filePath = path.join(directory, name);
  fs.writeFileSync(filePath, contents, { mode: 0o755 });
  return filePath;
}

function releaseEnvironment(overrides = {}) {
  const environment = { ...process.env };
  delete environment.SKIP_UPLOAD;
  delete environment.TOASTTY_IOS_SKIP_UPLOAD;
  delete environment.TOASTTY_IOS_UPLOAD;
  return {
    ...environment,
    APP_STORE_CONNECT_API_KEY_ID: "key-id",
    APP_STORE_CONNECT_API_ISSUER_ID: "issuer-id",
    APP_STORE_CONNECT_API_PRIVATE_KEY: "private-key-fixture",
    TOASTTY_IOS_DEVELOPMENT_TEAM: "TEAM123",
    IOS_DISTRIBUTION_CERTIFICATE_BASE64: "certificate-fixture",
    IOS_DISTRIBUTION_CERTIFICATE_PASSWORD: "password-fixture",
    IOS_APPSTORE_PROVISIONING_PROFILE_BASE64: "profile-fixture",
    TUIST_TOASTTY_MOBILE_VERSION: "1.5.0",
    TUIST_TOASTTY_MOBILE_BUILD_NUMBER: "123.1",
    ...overrides,
  };
}

test("release dry-run validates static configuration without release tooling or secrets", () => {
  const output = execFileSync("bash", [releaseScript, "--dry-run"], {
    cwd: repositoryRoot,
    encoding: "utf8",
    env: {
      PATH: process.env.PATH,
      TOASTTY_IOS_UPLOAD: "1",
    },
  });

  assert.match(output, /Static release configuration is valid/);
  assert.match(output, /archive ToasttyMobileApp-Release as com\.giantthings\.toastty\.mobile/);
  assert.match(output, /Upload remains disabled unless TOASTTY_IOS_UPLOAD=1/);
});

test("release script is safe-by-default and validates before explicit upload", () => {
  const script = fs.readFileSync(releaseScript, "utf8");
  const validationIndex = script.indexOf("--validate-app");
  const uploadGateIndex = script.indexOf('if [[ "$UPLOAD_REQUESTED" != "1" ]]');
  const uploadIndex = script.indexOf("--upload-app");

  assert.ok(validationIndex > 0);
  assert.ok(uploadGateIndex > validationIndex);
  assert.ok(uploadIndex > uploadGateIndex);
  assert.match(script, /UPLOAD_REQUESTED="\$\{TOASTTY_IOS_UPLOAD:-0\}"/);
  assert.match(script, /DOCUMENTED_SKIP_UPLOAD="\$\{SKIP_UPLOAD-0\}"/);
  assert.match(script, /trap cleanup EXIT/);
  assert.match(script, /profile_get_task_allow/);
  assert.match(script, /profile_provisioned_devices/);
  assert.match(script, /profile_provisions_all_devices/);
  assert.match(script, /OTHER_CODE_SIGN_FLAGS = --keychain/);
  assert.match(script, /framework targets must not receive the app provisioning profile/);
  assert.match(script, /CFBundleIconName/);
  assert.match(script, /PrivacyInfo\.xcprivacy/);
});

test("stubbed release runs prove both skip inputs and the explicit upload path", () => {
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "toastty-ios-release-test-"));
  const binDirectory = path.join(temporaryDirectory, "bin");
  const homeDirectory = path.join(temporaryDirectory, "home");
  const toolLog = path.join(temporaryDirectory, "tool.log");
  fs.mkdirSync(binDirectory);
  fs.mkdirSync(homeDirectory);

  writeExecutable(binDirectory, "base64", "#!/bin/sh\n/bin/cat\n");
  writeExecutable(binDirectory, "uuidgen", "#!/bin/sh\nprintf '00000000-0000-0000-0000-000000000000\\n'\n");
  writeExecutable(binDirectory, "tuist", "#!/bin/sh\nprintf 'tuist %s\\n' \"$*\" >>\"$TOOL_LOG\"\n");
  writeExecutable(binDirectory, "security", `#!/bin/sh
case "$1" in
  default-keychain)
    if [ "$4" = "" ]; then printf '"/tmp/login.keychain-db"\\n'; fi
    ;;
  list-keychains)
    if [ "$4" = "" ]; then printf '    "/tmp/login.keychain-db"\\n'; fi
    ;;
  find-identity)
    printf '1) ABCDEF "Apple Distribution: Toastty"\\n'
    ;;
esac
exit 0
`);
  const plistBuddy = writeExecutable(binDirectory, "PlistBuddy", `#!/bin/sh
key=${"${2#Print :}"}
file=$3
case "$file:$key" in
  *appstore-profile.plist:UUID) printf 'PROFILE-UUID\\n' ;;
  *appstore-profile.plist:Name) printf 'Toastty App Store\\n' ;;
  *appstore-profile.plist:TeamIdentifier:0) printf '%s\\n' "$TOASTTY_IOS_DEVELOPMENT_TEAM" ;;
  *appstore-profile.plist:Entitlements:application-identifier) printf '%s.com.giantthings.toastty.mobile\\n' "$TOASTTY_IOS_DEVELOPMENT_TEAM" ;;
  *appstore-profile.plist:Entitlements:get-task-allow) printf 'false\\n' ;;
  *appstore-profile.plist:Entitlements:ProvisionedDevices|*appstore-profile.plist:Entitlements:ProvisionsAllDevices) exit 1 ;;
  *ExportOptions.plist:method) printf 'app-store-connect\\n' ;;
  *ExportOptions.plist:signingStyle) printf 'manual\\n' ;;
  *ExportOptions.plist:teamID) printf '%s\\n' "$TOASTTY_IOS_DEVELOPMENT_TEAM" ;;
  *ExportOptions.plist:provisioningProfiles:com.giantthings.toastty.mobile) printf 'Toastty App Store\\n' ;;
  *Toastty.app/Info.plist:CFBundleIdentifier) printf 'com.giantthings.toastty.mobile\\n' ;;
  *Toastty.app/Info.plist:CFBundleShortVersionString) printf '%s\\n' "$TUIST_TOASTTY_MOBILE_VERSION" ;;
  *Toastty.app/Info.plist:CFBundleVersion) printf '%s\\n' "$TUIST_TOASTTY_MOBILE_BUILD_NUMBER" ;;
  *Toastty.app/Info.plist:CFBundleIconName) printf 'AppIcon\\n' ;;
  *Toastty.app/Info.plist:ITSAppUsesNonExemptEncryption) printf 'false\\n' ;;
  *PrivacyInfo.xcprivacy:NSPrivacyTracking) printf 'false\\n' ;;
  *PrivacyInfo.xcprivacy:NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPIType) printf 'NSPrivacyAccessedAPICategoryUserDefaults\\n' ;;
  *PrivacyInfo.xcprivacy:NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPITypeReasons:0) printf 'CA92.1\\n' ;;
  *PrivacyInfo.xcprivacy:NSPrivacyAccessedAPITypes:1:NSPrivacyAccessedAPIType) printf 'NSPrivacyAccessedAPICategorySystemBootTime\\n' ;;
  *PrivacyInfo.xcprivacy:NSPrivacyAccessedAPITypes:1:NSPrivacyAccessedAPITypeReasons:0) printf '35F9.1\\n' ;;
  *PrivacyInfo.xcprivacy:NSPrivacyAccessedAPITypes|*PrivacyInfo.xcprivacy:NSPrivacyCollectedDataTypes|*PrivacyInfo.xcprivacy:NSPrivacyTrackingDomains) printf 'Array {\\n}\\n' ;;
  *) exit 1 ;;
esac
`);
  writeExecutable(binDirectory, "xcodebuild", `#!/bin/sh
printf 'xcodebuild %s\\n' "$*" >>"$TOOL_LOG"
case " $* " in
  *" -showBuildSettings "*)
    case " $* " in
      *" -target ToasttyMobileApp "*)
        printf '    PRODUCT_BUNDLE_IDENTIFIER = com.giantthings.toastty.mobile\\n'
        printf '    CODE_SIGN_IDENTITY = Apple Distribution\\n'
        printf '    CODE_SIGN_STYLE = Manual\\n'
        printf '    PROVISIONING_PROFILE_SPECIFIER = Toastty App Store\\n'
        printf '    OTHER_CODE_SIGN_FLAGS = %s\\n' "$TUIST_TOASTTY_MOBILE_RELEASE_OTHER_CODE_SIGN_FLAGS"
        ;;
      *) printf '    PRODUCT_NAME = Framework\\n' ;;
    esac
    ;;
  *" archive "*)
    app="$TOASTTY_IOS_RELEASE_OUTPUT_DIR/Toastty.xcarchive/Products/Applications/Toastty.app"
    mkdir -p "$app"
    : >"$app/Info.plist"
    printf 'assets' >"$app/Assets.car"
    : >"$app/PrivacyInfo.xcprivacy"
    ;;
  *" -exportArchive "*)
    mkdir -p "$TOASTTY_IOS_RELEASE_OUTPUT_DIR/export"
    printf 'ipa' >"$TOASTTY_IOS_RELEASE_OUTPUT_DIR/export/Toastty.ipa"
    ;;
esac
`);
  writeExecutable(binDirectory, "xcrun", "#!/bin/sh\nprintf 'xcrun %s\\n' \"$*\" >>\"$TOOL_LOG\"\n");

  try {
    function runStubbedRelease(label, overrides) {
      const outputDirectory = path.join(temporaryDirectory, label);
      fs.writeFileSync(toolLog, "");
      const output = execFileSync("bash", [releaseScript], {
        cwd: repositoryRoot,
        encoding: "utf8",
        env: releaseEnvironment({
          PATH: `${binDirectory}:${process.env.PATH}`,
          HOME: homeDirectory,
          TOOL_LOG: toolLog,
          TOASTTY_IOS_PLIST_BUDDY: plistBuddy,
          TOASTTY_IOS_RELEASE_OUTPUT_DIR: outputDirectory,
          GITHUB_REF: "refs/heads/main",
          ...overrides,
        }),
      });
      return {
        output,
        outputDirectory,
        invocations: fs.readFileSync(toolLog, "utf8"),
        metadata: fs.readFileSync(
          path.join(outputDirectory, "release-metadata.txt"),
          "utf8",
        ),
      };
    }

    const documentedSkip = runStubbedRelease("documented-skip", {
      TOASTTY_IOS_UPLOAD: "1",
      SKIP_UPLOAD: "1",
    });
    assert.match(documentedSkip.invocations, /xcrun altool --validate-app/);
    assert.doesNotMatch(documentedSkip.invocations, /--upload-app/);
    assert.match(documentedSkip.invocations, /tuist install/);
    assert.match(documentedSkip.invocations, /tuist generate --no-open/);
    assert.match(documentedSkip.invocations, /xcodebuild .* -scheme ToasttyMobileApp-Release .* archive/);
    assert.ok(fs.existsSync(path.join(documentedSkip.outputDirectory, "export/Toastty.ipa")));
    assert.match(documentedSkip.output, /Upload request suppressed by validate-only skip input/);
    assert.match(documentedSkip.metadata, /STATUS=validated/);
    assert.match(documentedSkip.metadata, /UPLOAD_REQUESTED_ORIGINAL=1/);
    assert.match(documentedSkip.metadata, /UPLOAD_REQUESTED=0/);
    assert.match(documentedSkip.metadata, /UPLOAD_SUPPRESSED_BY=SKIP_UPLOAD/);

    const scopedSkip = runStubbedRelease("scoped-skip", {
      TOASTTY_IOS_UPLOAD: "1",
      TOASTTY_IOS_SKIP_UPLOAD: "1",
    });
    assert.match(scopedSkip.invocations, /xcrun altool --validate-app/);
    assert.doesNotMatch(scopedSkip.invocations, /--upload-app/);
    assert.match(scopedSkip.metadata, /UPLOAD_REQUESTED_ORIGINAL=1/);
    assert.match(scopedSkip.metadata, /UPLOAD_REQUESTED=0/);
    assert.match(scopedSkip.metadata, /UPLOAD_SUPPRESSED_BY=TOASTTY_IOS_SKIP_UPLOAD/);

    const upload = runStubbedRelease("upload", {
      TOASTTY_IOS_UPLOAD: "1",
    });
    assert.match(upload.invocations, /xcrun altool --validate-app/);
    assert.match(upload.invocations, /xcrun altool --upload-app/);
    assert.match(upload.metadata, /STATUS=uploaded/);
    assert.match(upload.metadata, /UPLOAD_REQUESTED_ORIGINAL=1/);
    assert.match(upload.metadata, /UPLOAD_REQUESTED=1/);
    assert.match(upload.metadata, /UPLOAD_SUPPRESSED_BY=none/);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("release script rejects upload away from main before touching signing assets", () => {
  let error;
  try {
    execFileSync("bash", [releaseScript], {
      cwd: repositoryRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      env: releaseEnvironment({
        TOASTTY_IOS_UPLOAD: "1",
        GITHUB_REF: "refs/heads/feature/release-test",
      }),
    });
  } catch (caught) {
    error = caught;
  }
  assert.ok(error);
  assert.match(error.stderr, /upload is allowed only from refs\/heads\/main/);
});

test("documented skip-upload input is fail-closed", () => {
  let error;
  try {
    execFileSync("bash", [releaseScript], {
      cwd: repositoryRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      env: releaseEnvironment({ SKIP_UPLOAD: "true" }),
    });
  } catch (caught) {
    error = caught;
  }
  assert.ok(error);
  assert.match(error.stderr, /SKIP_UPLOAD must be 0 or 1/);
});

test("empty documented skip-upload input is fail-closed", () => {
  let error;
  try {
    execFileSync("bash", [releaseScript], {
      cwd: repositoryRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      env: releaseEnvironment({ SKIP_UPLOAD: "" }),
    });
  } catch (caught) {
    error = caught;
  }
  assert.ok(error);
  assert.match(error.stderr, /SKIP_UPLOAD must be 0 or 1/);
});

test("scoped skip-upload input is fail-closed", () => {
  let error;
  try {
    execFileSync("bash", [releaseScript], {
      cwd: repositoryRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      env: releaseEnvironment({ TOASTTY_IOS_SKIP_UPLOAD: "true" }),
    });
  } catch (caught) {
    error = caught;
  }
  assert.ok(error);
  assert.match(error.stderr, /TOASTTY_IOS_SKIP_UPLOAD must be 0 or 1/);
});

test("production project wiring limits release signing overrides to the app target", () => {
  const manifest = fs.readFileSync(projectManifest, "utf8");
  const appSettingsIndex = manifest.indexOf("var appSettings: SettingsDictionary");
  const appTargetIndex = manifest.indexOf('name: "ToasttyMobileApp"');
  const domainTargetIndex = manifest.indexOf('name: "ToasttyMobileDomain"');

  assert.match(manifest, /ASSETCATALOG_COMPILER_APPICON_NAME.*AppIcon/);
  assert.match(manifest, /CFBundleIconName.*AppIcon/);
  assert.match(manifest, /TUIST_TOASTTY_MOBILE_RELEASE_OTHER_CODE_SIGN_FLAGS/);
  assert.ok(appSettingsIndex > 0 && appTargetIndex > appSettingsIndex);
  assert.ok(domainTargetIndex > appTargetIndex);
  assert.equal(
    manifest.slice(domainTargetIndex).includes("PROVISIONING_PROFILE_SPECIFIER"),
    false,
  );
});

test("app icon catalog supplies every declared file and production slots", () => {
  const catalog = JSON.parse(fs.readFileSync(path.join(iconSetDirectory, "Contents.json"), "utf8"));
  const productionSlots = new Set([
    "iphone:20x20:2x", "iphone:20x20:3x",
    "iphone:29x29:2x", "iphone:29x29:3x",
    "iphone:40x40:2x", "iphone:40x40:3x",
    "iphone:60x60:2x", "iphone:60x60:3x",
    "ios-marketing:1024x1024:1x",
  ]);

  for (const image of catalog.images) {
    assert.ok(fs.statSync(path.join(iconSetDirectory, image.filename)).size > 0);
    productionSlots.delete(`${image.idiom}:${image.size}:${image.scale}`);
  }
  assert.deepEqual([...productionSlots], []);
});

test("asset catalog supplies the Toastty amber AccentColor expected by actool", () => {
  const accent = JSON.parse(read(
    "ios/Resources/ToasttyMobileApp/Assets.xcassets/AccentColor.colorset/Contents.json",
  ));
  assert.equal(accent.colors.length, 1);
  assert.deepEqual(accent.colors[0], {
    color: {
      "color-space": "srgb",
      components: {
        alpha: "1.000000",
        blue: "0.047059",
        green: "0.576471",
        red: "0.909804",
      },
    },
    idiom: "universal",
  });
});

test("workflow and names-only manifest expose all release inputs without enabling push upload", () => {
  const workflow = fs.readFileSync(workflowPath, "utf8");
  const mobileWorkflow = fs.readFileSync(mobileWorkflowPath, "utf8");
  const secrets = fs.readFileSync(secretsManifest, "utf8");
  const requiredSecrets = [
    "APP_STORE_CONNECT_API_KEY_ID",
    "APP_STORE_CONNECT_API_ISSUER_ID",
    "TOASTTY_IOS_DEVELOPMENT_TEAM",
    "IOS_DISTRIBUTION_CERTIFICATE_BASE64",
    "IOS_DISTRIBUTION_CERTIFICATE_PASSWORD",
    "IOS_APPSTORE_PROVISIONING_PROFILE_BASE64",
  ];

  assert.match(workflow, /default: false/);
  assert.match(workflow, /environment: testflight/);
  assert.match(workflow, /vars\.TOASTTY_IOS_TESTFLIGHT_ON_PUSH == 'true'/);
  assert.match(workflow, /github\.ref == 'refs\/heads\/main' && github\.event_name == 'workflow_dispatch' && inputs\.upload == true/);
  assert.match(workflow, /inputs\.upload && github\.ref != 'refs\/heads\/main'/);
  assert.match(workflow, /inputs\.run_tests \|\| inputs\.upload/);
  for (const name of requiredSecrets) {
    assert.ok(secrets.split("\n").some((line) => line === `${name}?`));
    assert.match(workflow, new RegExp(`secrets\\.${name}`));
  }
  assert.match(secrets, /^APP_STORE_CONNECT_API_PRIVATE_KEY\?$/m);
  assert.match(secrets, /^APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64\?$/m);
  assert.equal(read(".node-version").trim(), "22.23.2");
  assert.equal(read(".tool-versions").trim(), "tuist 4.202.6");
  for (const configuredWorkflow of [workflow, mobileWorkflow]) {
    assert.match(configuredWorkflow, /node-version-file: \.node-version/);
    assert.match(configuredWorkflow, /mise install "tuist@\$TUIST_VERSION" --quiet/);
    assert.match(configuredWorkflow, /echo "\$TUIST_BIN_DIR" >> "\$GITHUB_PATH"/);
    assert.match(configuredWorkflow, /test "\$\("\$TUIST_BIN_DIR\/tuist" version\)" = "\$TUIST_VERSION"/);
  }
  assert.match(workflow, /Tests\/RemoteProtocol\/\*\*/);
  assert.match(workflow, /\.node-version/);
  assert.match(workflow, /\.tool-versions/);
  assert.match(mobileWorkflow, /'\.node-version'/);
  assert.match(mobileWorkflow, /'\.tool-versions'/);
});

test("privacy manifest declares required-reason APIs without tracking or collected data", () => {
  const privacyManifest = read("ios/Resources/ToasttyMobileApp/PrivacyInfo.xcprivacy");
  assert.match(privacyManifest, /<key>NSPrivacyTracking<\/key>\s*<false\/>/);
  for (const key of ["NSPrivacyCollectedDataTypes", "NSPrivacyTrackingDomains"]) {
    assert.match(privacyManifest, new RegExp(`<key>${key}<\\/key>\\s*<array\\/>`));
  }
  assert.match(privacyManifest, /NSPrivacyAccessedAPICategoryUserDefaults/);
  assert.match(privacyManifest, /<string>CA92\.1<\/string>/);
  assert.match(privacyManifest, /NSPrivacyAccessedAPICategorySystemBootTime/);
  assert.match(privacyManifest, /<string>35F9\.1<\/string>/);
});
