import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
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
    GITHUB_ACTIONS: "false",
    APP_STORE_CONNECT_API_KEY_ID: "key-id",
    APP_STORE_CONNECT_API_ISSUER_ID: "issuer-id",
    APP_STORE_CONNECT_API_PRIVATE_KEY: "private-key-fixture",
    APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64: "",
    TOASTTY_IOS_DEVELOPMENT_TEAM: "TEAM123",
    IOS_DISTRIBUTION_CERTIFICATE_BASE64: "certificate-fixture",
    IOS_DISTRIBUTION_CERTIFICATE_PASSWORD: "password-fixture",
    IOS_APPSTORE_PROVISIONING_PROFILE_BASE64: "profile-fixture",
    TUIST_TOASTTY_MOBILE_VERSION: "1.5.0",
    TUIST_TOASTTY_MOBILE_BUILD_NUMBER: "123.1",
    TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL: "https://push.example.com",
    TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_ID: "toastty-push-production-v1",
    TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_ENVIRONMENT: "production",
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

test("stubbed release enforces production push gates for signed validation and upload", () => {
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "toastty-ios-release-test-"));
  const binDirectory = path.join(temporaryDirectory, "bin");
  const homeDirectory = path.join(temporaryDirectory, "home");
  const toolLog = path.join(temporaryDirectory, "tool.log");
  fs.mkdirSync(binDirectory);
  fs.mkdirSync(homeDirectory);

  const realGit = execFileSync("which", ["git"], { encoding: "utf8" }).trim();
  writeExecutable(binDirectory, "git", `#!/bin/sh
if [ "$3" = diff ]; then exit "${"${STUB_DIRTY_TRACKED_SOURCE:-0}"}"; fi
exec "${realGit}" "$@"
`);
  writeExecutable(binDirectory, "base64", "#!/bin/sh\n/bin/cat\n");
  writeExecutable(binDirectory, "uuidgen", "#!/bin/sh\nprintf '00000000-0000-0000-0000-000000000000\\n'\n");
  // The real dry-run above covers icon inspection. Keep repeated signed-flow
  // fixtures fast while retaining the static checks' required tool output.
  writeExecutable(binDirectory, "sips", `#!/bin/sh
for argument do filename=$argument; done
case "\${filename##*/}" in
  App-Icon-20x20@1x.png) pixels=20 ;;
  App-Icon-20x20@2x.png|App-Icon-40x40@1x.png) pixels=40 ;;
  App-Icon-20x20@3x.png) pixels=60 ;;
  App-Icon-29x29@1x.png) pixels=29 ;;
  App-Icon-29x29@2x.png) pixels=58 ;;
  App-Icon-29x29@3x.png) pixels=87 ;;
  App-Icon-40x40@2x.png) pixels=80 ;;
  App-Icon-40x40@3x.png|App-Icon-60x60@2x.png) pixels=120 ;;
  App-Icon-60x60@3x.png) pixels=180 ;;
  App-Icon-76x76@1x.png) pixels=76 ;;
  App-Icon-76x76@2x.png) pixels=152 ;;
  App-Icon-83.5x83.5@2x.png) pixels=167 ;;
  App-Icon-1024x1024@1x.png) pixels=1024 ;;
  *) exit 1 ;;
esac
printf 'pixelWidth: %s\\npixelHeight: %s\\nhasAlpha: no\\n' "$pixels" "$pixels"
`);
  writeExecutable(binDirectory, "tuist", `#!/bin/sh
printf 'tuist %s\\n' "$*" >>"$TOOL_LOG"
if [ "$1" = version ]; then printf '4.202.6\\n'; fi
if [ "$1" = generate ]; then
  printf 'tuist push %s %s %s\\n' "$TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL" "$TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_ID" "$TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_ENVIRONMENT" >>"$TOOL_LOG"
fi
`);
  writeExecutable(binDirectory, "security", `#!/bin/sh
printf 'security %s\\n' "$*" >>"$TOOL_LOG"
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
  *appstore-profile.plist:Entitlements:aps-environment) printf '%s\\n' "\${STUB_INPUT_PROFILE_ENVIRONMENT-production}" ;;
  *appstore-profile.plist:Entitlements:ProvisionedDevices|*appstore-profile.plist:Entitlements:ProvisionsAllDevices) exit 1 ;;
  *embedded-profile.plist:TeamIdentifier:0) printf '%s\\n' "\${STUB_EXPORTED_PROFILE_TEAM-$TOASTTY_IOS_DEVELOPMENT_TEAM}" ;;
  *embedded-profile.plist:Entitlements:application-identifier) printf '%s\\n' "\${STUB_EXPORTED_PROFILE_APP_ID-$TOASTTY_IOS_DEVELOPMENT_TEAM.com.giantthings.toastty.mobile}" ;;
  *embedded-profile.plist:Entitlements:get-task-allow) printf '%s\\n' "\${STUB_EXPORTED_GET_TASK_ALLOW-false}" ;;
  *embedded-profile.plist:Entitlements:aps-environment) printf '%s\\n' "\${STUB_EXPORTED_PROFILE_ENVIRONMENT-production}" ;;
  *embedded-profile.plist:ProvisionedDevices) if [ "$STUB_EXPORTED_AD_HOC" = 1 ]; then printf 'Array { device }\\n'; else exit 1; fi ;;
  *embedded-profile.plist:ProvisionsAllDevices) if [ "$STUB_EXPORTED_ENTERPRISE" = 1 ]; then printf 'true\\n'; else exit 1; fi ;;
  *signed-entitlements.plist:application-identifier) printf '%s\\n' "\${STUB_SIGNED_APP_ID-$TOASTTY_IOS_DEVELOPMENT_TEAM.com.giantthings.toastty.mobile}" ;;
  *signed-entitlements.plist:com.apple.developer.team-identifier) printf '%s\\n' "\${STUB_SIGNED_TEAM-$TOASTTY_IOS_DEVELOPMENT_TEAM}" ;;
  *signed-entitlements.plist:get-task-allow) printf '%s\\n' "\${STUB_SIGNED_GET_TASK_ALLOW-false}" ;;
  *signed-entitlements.plist:aps-environment) printf '%s\\n' "\${STUB_SIGNED_ENVIRONMENT-production}" ;;
  *ExportOptions.plist:method) printf 'app-store-connect\\n' ;;
  *ExportOptions.plist:signingStyle) printf 'manual\\n' ;;
  *ExportOptions.plist:teamID) printf '%s\\n' "$TOASTTY_IOS_DEVELOPMENT_TEAM" ;;
  *ExportOptions.plist:provisioningProfiles:com.giantthings.toastty.mobile) printf 'Toastty App Store\\n' ;;
  *Payload/Toastty.app/Info.plist:CFBundleIdentifier) printf '%s\\n' "\${STUB_EXPORTED_BUNDLE_ID-com.giantthings.toastty.mobile}" ;;
  *Payload/Toastty.app/Info.plist:CFBundleShortVersionString) printf '%s\\n' "\${STUB_EXPORTED_VERSION-$TUIST_TOASTTY_MOBILE_VERSION}" ;;
  *Payload/Toastty.app/Info.plist:CFBundleVersion) printf '%s\\n' "\${STUB_EXPORTED_BUILD-$TUIST_TOASTTY_MOBILE_BUILD_NUMBER}" ;;
  *Payload/Toastty.app/Info.plist:ToasttyMobilePushRelayURL) printf '%s\\n' "\${STUB_EXPORTED_PUSH_URL-$TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL}" ;;
  *Payload/Toastty.app/Info.plist:ToasttyMobilePushRelayID) printf '%s\\n' "\${STUB_EXPORTED_PUSH_ID-$TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_ID}" ;;
  *Payload/Toastty.app/Info.plist:ToasttyMobilePushEnvironment) printf '%s\\n' "\${STUB_EXPORTED_PUSH_ENVIRONMENT-$TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_ENVIRONMENT}" ;;
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
  writeExecutable(binDirectory, "codesign", `#!/bin/sh
printf 'codesign %s\\n' "$*" >>"$TOOL_LOG"
if [ "$1" = --verify ] && [ "$STUB_INVALID_SIGNATURE" = 1 ]; then exit 1; fi
if [ "$1" = --display ]; then
  if [ "$2" != --entitlements ] || [ "$3" != - ] || [ "$4" != --xml ]; then exit 1; fi
  if [ "$STUB_MUTATE_VERIFY_IPA" = 1 ]; then printf 'changed' >>"$TOASTTY_IOS_RELEASE_OUTPUT_DIR/export/Toastty.ipa"; fi
  printf '<plist><dict/></plist>\\n'
fi
`);
  writeExecutable(binDirectory, "xcodebuild", `#!/bin/sh
printf 'xcodebuild %s\\n' "$*" >>"$TOOL_LOG"
case " $* " in
  *" -version "*) printf 'Xcode 26.0\\nBuild version 17A123\\n' ;;
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
    symbols="$TOASTTY_IOS_RELEASE_OUTPUT_DIR/Toastty.xcarchive/dSYMs/Toastty.app.dSYM/Contents/Resources/DWARF"
    mkdir -p "$symbols"
    if [ "$STUB_OMIT_SYMBOLS" != 1 ]; then printf 'symbols' >"$symbols/Toastty"; fi
    ;;
  *" -exportArchive "*)
    payload="$TOASTTY_IOS_RELEASE_OUTPUT_DIR/export/Payload"
    mkdir -p "$payload"
    cp -R "$TOASTTY_IOS_RELEASE_OUTPUT_DIR/Toastty.xcarchive/Products/Applications/Toastty.app" "$payload/Toastty.app"
    if [ "$STUB_OMIT_EMBEDDED_PROFILE" != 1 ]; then printf 'profile' >"$payload/Toastty.app/embedded.mobileprovision"; fi
    if [ "$STUB_EXTRA_APP" = 1 ]; then cp -R "$payload/Toastty.app" "$payload/Other.app"; fi
    if [ "$STUB_OMIT_EXPORTED_PLIST" = 1 ]; then rm "$payload/Toastty.app/Info.plist"; fi
    (cd "$TOASTTY_IOS_RELEASE_OUTPUT_DIR/export" && /usr/bin/zip -q -r Toastty.ipa Payload)
    if [ "$STUB_INVALID_IPA" = 1 ]; then printf 'invalid' >"$TOASTTY_IOS_RELEASE_OUTPUT_DIR/export/Toastty.ipa"; fi
    ;;
esac
`);
  writeExecutable(binDirectory, "xcrun", `#!/bin/sh
printf 'xcrun %s\\n' "$*" >>"$TOOL_LOG"
case "$*" in
  "swift --version") printf 'Apple Swift version 6.2\\n' ;;
  "--sdk iphoneos --show-sdk-version") printf '26.0\\n' ;;
  "altool --validate-app"*)
    if [ "$STUB_MUTATE_VALIDATED_IPA" = 1 ]; then printf 'changed' >>"$TOASTTY_IOS_RELEASE_OUTPUT_DIR/export/Toastty.ipa"; fi
    ;;
esac
`);

  try {
    function runStubbedRelease(label, overrides) {
      const outputDirectory = path.join(temporaryDirectory, label);
      fs.writeFileSync(toolLog, "");
      const output = execFileSync("bash", [releaseScript], {
        cwd: repositoryRoot,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
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
      GITHUB_SHA: "ci-event-fixture",
    });
    assert.match(documentedSkip.invocations, /xcrun altool --validate-app/);
    assert.doesNotMatch(documentedSkip.invocations, /--upload-app/);
    assert.match(documentedSkip.invocations, /tuist install/);
    assert.match(documentedSkip.invocations, /tuist generate --no-open/);
    assert.match(documentedSkip.invocations, /tuist push https:\/\/push\.example\.com toastty-push-production-v1 production/);
    assert.match(documentedSkip.invocations, /xcodebuild .* -scheme ToasttyMobileApp-Release .* archive/);
    assert.ok(fs.existsSync(path.join(documentedSkip.outputDirectory, "export/Toastty.ipa")));
    assert.match(documentedSkip.output, /Upload request suppressed by validate-only skip input/);
    assert.match(documentedSkip.metadata, /STATUS=validated/);
    assert.match(documentedSkip.metadata, /GIT_SHA=[a-f0-9]{40}\n/);
    assert.match(documentedSkip.metadata, /CI_EVENT_SHA=ci-event-fixture\n/);
    assert.match(documentedSkip.metadata, /XCODE_VERSION=Xcode 26.0 Build version 17A123/);
    assert.match(documentedSkip.metadata, /SWIFT_VERSION=Apple Swift version 6.2/);
    assert.match(documentedSkip.metadata, /IOS_SDK_VERSION=26.0/);
    assert.match(documentedSkip.metadata, /TUIST_VERSION=4.202.6/);
    const retainedArchive = path.join(documentedSkip.outputDirectory, "Toastty.xcarchive.tar.gz");
    const archiveContents = execFileSync("tar", ["-tzf", retainedArchive], { encoding: "utf8" });
    assert.match(archiveContents, /Toastty\.xcarchive\/Products\/Applications\/Toastty\.app\/Info\.plist/);
    assert.match(archiveContents, /Toastty\.app\.dSYM\/Contents\/Resources\/DWARF\/Toastty/);
    assert.match(documentedSkip.metadata, /UPLOAD_REQUESTED_ORIGINAL=1/);
    assert.match(documentedSkip.metadata, /UPLOAD_REQUESTED=0/);
    assert.match(documentedSkip.metadata, /UPLOAD_SUPPRESSED_BY=SKIP_UPLOAD/);
    assert.match(documentedSkip.invocations, /codesign --verify --strict/);
    assert.match(documentedSkip.invocations, /codesign --display --entitlements - --xml/);
    assert.match(documentedSkip.metadata, /PUSH_RELAY_URL=https:\/\/push\.example\.com\n/);
    assert.match(documentedSkip.metadata, /PUSH_RELAY_ID=toastty-push-production-v1\n/);
    assert.match(documentedSkip.metadata, /PUSH_ENVIRONMENT=production\n/);
    const ipaHash = createHash("sha256")
      .update(fs.readFileSync(path.join(documentedSkip.outputDirectory, "export/Toastty.ipa")))
      .digest("hex");
    assert.ok(documentedSkip.metadata.includes(`IPA_SHA256=${ipaHash}\n`));

    const boundary = runStubbedRelease("valid-boundaries", {
      TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL: "https://push.example.com:443/",
      TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_ID: "é".repeat(64),
    });
    assert.match(boundary.invocations, /tuist push https:\/\/push\.example\.com:443\//);
    assert.match(boundary.invocations, /--validate-app/);
    assert.doesNotMatch(boundary.invocations, /--upload-app/);

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
      GITHUB_ACTIONS: "true",
      GITHUB_SHA: execFileSync("git", ["rev-parse", "HEAD"], { cwd: repositoryRoot, encoding: "utf8" }).trim(),
      TOASTTY_IOS_VERIFIED_SHA: execFileSync("git", ["rev-parse", "HEAD"], { cwd: repositoryRoot, encoding: "utf8" }).trim(),
    });
    assert.match(upload.invocations, /xcrun altool --validate-app/);
    assert.match(upload.invocations, /xcrun altool --upload-app/);
    assert.match(upload.metadata, /STATUS=uploaded/);
    assert.match(upload.metadata, /UPLOAD_REQUESTED_ORIGINAL=1/);
    assert.match(upload.metadata, /UPLOAD_REQUESTED=1/);
    assert.match(upload.metadata, /UPLOAD_SUPPRESSED_BY=none/);

    assert.throws(() => runStubbedRelease("changed-source", {
      GITHUB_ACTIONS: "true",
      GITHUB_SHA: execFileSync("git", ["rev-parse", "HEAD"], { cwd: repositoryRoot, encoding: "utf8" }).trim(),
      TOASTTY_IOS_VERIFIED_SHA: execFileSync("git", ["rev-parse", "HEAD"], { cwd: repositoryRoot, encoding: "utf8" }).trim(),
      STUB_DIRTY_TRACKED_SOURCE: "1",
    }), (error) => {
      assert.match(error.stderr.toString(), /tracked source modified after checkout/);
      assert.equal(fs.readFileSync(toolLog, "utf8"), "");
      return true;
    });

    assert.throws(() => runStubbedRelease("missing-symbols", {
      TOASTTY_IOS_UPLOAD: "0",
      STUB_OMIT_SYMBOLS: "1",
    }), (error) => {
      assert.match(error.stderr.toString(), /archived app is missing its dSYM debug symbols/);
      assert.doesNotMatch(fs.readFileSync(toolLog, "utf8"), /--validate-app|--upload-app/);
      return true;
    });

    // Configuration gaps must stop both signed validation and upload before
    // any certificate/profile decoding, Keychain mutation, or build tool runs.
    const invalidConfigurations = [
      ["missing-url", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL: "" }, /PRODUCTION_RELAY_URL is required/],
      ["missing-id", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_ID: "" }, /PRODUCTION_RELAY_ID is required/],
      ["missing-environment", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_ENVIRONMENT: "" }, /PRODUCTION_ENVIRONMENT is required/],
      ["sandbox-environment", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_ENVIRONMENT: "development" }, /must be production/],
      ["http-url", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL: "http://push.example.com" }, /HTTPS origin/],
      ["credential-url", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL: "https://user:password@push.example.com" }, /HTTPS origin/],
      ["path-url", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL: "https://push.example.com/api" }, /HTTPS origin/],
      ["normalized-path-url", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL: "https://push.example.com/api/.." }, /HTTPS origin/],
      ["query-url", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL: "https://push.example.com?" }, /HTTPS origin/],
      ["fragment-url", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL: "https://push.example.com#" }, /HTTPS origin/],
      ["port-url", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL: "https://push.example.com:8443" }, /HTTPS origin/],
      ["whitespace-url", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL: " https://push.example.com" }, /surrounding whitespace/],
      ["whitespace-id", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_ID: "production " }, /surrounding whitespace/],
      ["control-id", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_ID: "production\nrelay" }, /control characters/],
      ["unresolved-url", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL: "https://$(PUSH_HOST)" }, /unresolved build setting/],
      ["unresolved-id", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_ID: "${PUSH_ID}" }, /unresolved build setting/],
      ["oversized-id", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_ID: "é".repeat(65) }, /128 UTF-8 bytes/],
      ["development-id", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_ID: "toastty-push-dev-v1" }, /development relay/],
      ["development-url", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL: "https://toastty-push-dev.giantthings.workers.dev/" }, /development relay/],
      ["trailing-dot-development-url", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL: "https://toastty-push-dev.giantthings.workers.dev./" }, /trailing-dot host/],
      ["trailing-dot-production-url", { TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL: "https://push.example.com./" }, /trailing-dot host/],
      ["configured-development-url", { TUIST_TOASTTY_MOBILE_PUSH_RELAY_URL: "https://push.example.com:443/" }, /development relay/],
      ["configured-development-id", { TUIST_TOASTTY_MOBILE_PUSH_RELAY_ID: "toastty-push-production-v1" }, /development relay/],
    ];
    for (const uploadRequested of ["0", "1"]) {
      for (const [label, overrides, expectedError] of invalidConfigurations) {
        assert.throws(() => runStubbedRelease(`${label}-${uploadRequested}`, {
          TOASTTY_IOS_UPLOAD: uploadRequested, ...overrides,
        }), (error) => {
          assert.match(error.stderr.toString(), expectedError);
          assert.equal(fs.readFileSync(toolLog, "utf8"), "");
          return true;
        });
      }
    }

    for (const environment of ["", "development"]) {
      assert.throws(() => runStubbedRelease(`input-profile-${environment || "missing"}`, {
        STUB_INPUT_PROFILE_ENVIRONMENT: environment,
      }), (error) => {
        assert.match(error.stderr.toString(), /provisioning profile must enable aps-environment=production/);
        assert.doesNotMatch(fs.readFileSync(toolLog, "utf8"), /security create-keychain|xcodebuild .* archive|--validate-app|--upload-app/);
        return true;
      });
    }

    // The exported file is authoritative. Generation/archive success cannot
    // substitute for its effective settings, signature, or embedded profile.
    const invalidExports = [
      ["missing-push-url", { STUB_EXPORTED_PUSH_URL: "" }, /ToasttyMobilePushRelayURL mismatch/],
      ["wrong-push-url", { STUB_EXPORTED_PUSH_URL: "https://other.example.com" }, /ToasttyMobilePushRelayURL mismatch/],
      ["wrong-push-id", { STUB_EXPORTED_PUSH_ID: "other-production" }, /ToasttyMobilePushRelayID mismatch/],
      ["wrong-push-environment", { STUB_EXPORTED_PUSH_ENVIRONMENT: "development" }, /ToasttyMobilePushEnvironment mismatch/],
      ["wrong-bundle", { STUB_EXPORTED_BUNDLE_ID: "com.giantthings.toastty.mobile.dev" }, /CFBundleIdentifier mismatch/],
      ["wrong-version", { STUB_EXPORTED_VERSION: "1.4.0" }, /CFBundleShortVersionString mismatch/],
      ["wrong-build", { STUB_EXPORTED_BUILD: "122.1" }, /CFBundleVersion mismatch/],
      ["missing-entitlement", { STUB_SIGNED_ENVIRONMENT: "" }, /aps-environment mismatch/],
      ["sandbox-entitlement", { STUB_SIGNED_ENVIRONMENT: "development" }, /aps-environment mismatch/],
      ["wrong-signed-team", { STUB_SIGNED_TEAM: "OTHERTEAM" }, /com.apple.developer.team-identifier mismatch/],
      ["wrong-signed-app", { STUB_SIGNED_APP_ID: "TEAM123.other.app" }, /application-identifier mismatch/],
      ["debuggable-signature", { STUB_SIGNED_GET_TASK_ALLOW: "true" }, /get-task-allow mismatch/],
      ["missing-embedded-profile", { STUB_OMIT_EMBEDDED_PROFILE: "1" }, /missing embedded provisioning profile/],
      ["missing-profile-entitlement", { STUB_EXPORTED_PROFILE_ENVIRONMENT: "" }, /Entitlements:aps-environment mismatch/],
      ["sandbox-profile-entitlement", { STUB_EXPORTED_PROFILE_ENVIRONMENT: "development" }, /Entitlements:aps-environment mismatch/],
      ["wrong-profile-team", { STUB_EXPORTED_PROFILE_TEAM: "OTHERTEAM" }, /TeamIdentifier:0 mismatch/],
      ["wrong-profile-app", { STUB_EXPORTED_PROFILE_APP_ID: "TEAM123.other.app" }, /Entitlements:application-identifier mismatch/],
      ["debuggable-profile", { STUB_EXPORTED_GET_TASK_ALLOW: "true" }, /Entitlements:get-task-allow mismatch/],
      ["ad-hoc-profile", { STUB_EXPORTED_AD_HOC: "1" }, /not development or Ad Hoc/],
      ["enterprise-profile", { STUB_EXPORTED_ENTERPRISE: "1" }, /not Enterprise/],
      ["extra-app", { STUB_EXTRA_APP: "1" }, /exactly one Toastty.app/],
      ["missing-exported-plist", { STUB_OMIT_EXPORTED_PLIST: "1" }, /exactly one Toastty.app/],
      ["invalid-zip", { STUB_INVALID_IPA: "1" }, /valid ZIP archive/],
      ["invalid-signature", { STUB_INVALID_SIGNATURE: "1" }, /exported app signature is invalid/],
      ["modified-during-verification", { STUB_MUTATE_VERIFY_IPA: "1" }, /IPA changed after verification/],
    ];
    for (const [label, overrides, expectedError] of invalidExports) {
      assert.throws(() => runStubbedRelease(label, {
        TOASTTY_IOS_UPLOAD: "1", ...overrides,
      }), (error) => {
        assert.match(error.stderr.toString(), expectedError);
        assert.doesNotMatch(fs.readFileSync(toolLog, "utf8"), /--validate-app|--upload-app/);
        return true;
      });
    }

    assert.throws(() => runStubbedRelease("modified-after-validation", {
      TOASTTY_IOS_UPLOAD: "1", STUB_MUTATE_VALIDATED_IPA: "1",
    }), (error) => {
      assert.match(error.stderr.toString(), /IPA changed after verification/);
      assert.match(fs.readFileSync(toolLog, "utf8"), /--validate-app/);
      assert.doesNotMatch(fs.readFileSync(toolLog, "utf8"), /--upload-app/);
      return true;
    });
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
  const mobileFilters = read(".github/ci-paths.yml");
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
  assert.doesNotMatch(workflow, /run_tests/);
  assert.match(workflow, /steps\.ci\.outputs\.verified_sha/);
  for (const name of requiredSecrets) {
    assert.ok(secrets.split("\n").some((line) => line === `${name}?`));
    assert.match(workflow, new RegExp(`secrets\\.${name}`));
  }
  for (const name of [
    "TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL",
    "TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_ID",
    "TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_ENVIRONMENT",
  ]) {
    assert.ok(secrets.split("\n").some((line) => line === `${name}?`));
    assert.match(workflow, new RegExp(`vars\\.${name}`));
  }
  assert.match(secrets, /^APP_STORE_CONNECT_API_PRIVATE_KEY\?$/m);
  assert.match(secrets, /^APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64\?$/m);
  assert.equal(read(".node-version").trim(), "22.23.2");
  assert.equal(read(".tool-versions").trim(), "tuist 4.202.6");
  for (const configuredWorkflow of [workflow, mobileWorkflow]) {
    assert.match(configuredWorkflow, /node-version-file: \.node-version/);
    assert.match(configuredWorkflow, /mise install "tuist@\$TUIST_VERSION" --quiet/);
    assert.ok(configuredWorkflow.includes('TUIST_BIN_DIR="$(dirname "$(mise exec "tuist@$TUIST_VERSION" -- which tuist)")"'));
    assert.match(configuredWorkflow, /echo "\$TUIST_BIN_DIR" >> "\$GITHUB_PATH"/);
    assert.match(configuredWorkflow, /test "\$\("\$TUIST_BIN_DIR\/tuist" version\)" = "\$TUIST_VERSION"/);
  }
  assert.match(workflow, /Tests\/RemoteProtocol\/\*\*/);
  assert.match(workflow, /\.node-version/);
  assert.match(workflow, /\.tool-versions/);
  assert.match(mobileWorkflow, /filters: \.github\/ci-paths\.yml/);
  assert.match(mobileFilters, /'\.node-version'/);
  assert.match(mobileFilters, /'\.tool-versions'/);
  assert.match(mobileFilters, /'\.github\/workflows\/ios-testflight\.yml'/);
  assert.match(mobileFilters, /'scripts\/ci\/\*\*'/);
  assert.match(mobileWorkflow, /node --test ios\/Tests\/ScriptTests\/\*\.test\.mjs ios\/Tests\/ReleaseScriptTests\/\*\.test\.mjs/);
  assert.match(mobileWorkflow, /configuration: \[Debug, Release\]/);
  assert.match(workflow, /require-ios-ci\.mjs/);
  assert.match(workflow, /artifacts\/ios-release\/\*\*\/Toastty\.xcarchive\.tar\.gz/);
  assert.match(workflow, /retention-days: 90/);
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

// Source mismatch must stop before invoking any signing or archive tools.
test("Actions release rejects absent or mismatched verified source", () => {
  const sha = execFileSync("git", ["rev-parse", "HEAD"], { cwd: repositoryRoot, encoding: "utf8" }).trim();
  for (const [verified, event] of [["", sha], ["0".repeat(40), sha], [sha, "0".repeat(40)]]) {
    assert.throws(() => execFileSync("bash", [releaseScript], {
      cwd: repositoryRoot, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
      env: { PATH: process.env.PATH, GITHUB_ACTIONS: "true", GITHUB_SHA: event,
        TOASTTY_IOS_VERIFIED_SHA: verified },
    }), (error) => {
      assert.match(error.stderr, /archive source must match the verified CI SHA/);
      return true;
    });
  }
});
