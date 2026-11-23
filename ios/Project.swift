import Foundation
import ProjectDescription

let environment = ProcessInfo.processInfo.environment

func manifestValue(_ keys: [String], default defaultValue: String) -> String {
    for key in keys {
        guard let value = environment[key] else { continue }
        guard !value.isEmpty else {
            fatalError("\(key) must not be empty when set at `tuist generate` time.")
        }
        return value
    }
    return defaultValue
}

func optionalManifestValue(_ keys: [String]) -> String? {
    for key in keys {
        guard let value = environment[key] else { continue }
        guard !value.isEmpty else {
            fatalError("\(key) must not be empty when set at `tuist generate` time.")
        }
        return value
    }
    return nil
}

func manifestFlag(_ key: String, default defaultValue: Bool = false) -> Bool {
    guard let value = environment[key] else { return defaultValue }
    switch value.lowercased() {
    case "1", "true", "yes", "on": return true
    case "0", "false", "no", "off": return false
    default: fatalError("\(key) must be a boolean flag when set at `tuist generate` time.")
    }
}

func sanitizedBundleSuffix(_ value: String) -> String {
    let components = value
        .split(separator: ".", omittingEmptySubsequences: true)
        .map { component in
            let normalized = component.lowercased().map { character -> Character in
                if character.isASCII, character.isLetter || character.isNumber || character == "-" {
                    return character
                }
                return "-"
            }
            return String(normalized)
                .split(separator: "-", omittingEmptySubsequences: true)
                .joined(separator: "-")
        }
        .filter { !$0.isEmpty }

    guard !components.isEmpty else { return ".dev.local" }
    return "." + String(components.joined(separator: ".").prefix(96))
}

func localHTTPAllowed(for value: String?) -> Bool {
    guard
        let value,
        let components = URLComponents(string: value),
        components.scheme?.lowercased() == "http",
        let host = components.host?.lowercased()
    else { return false }

    return host == "127.0.0.1"
        || host == "::1"
        || host == "localhost"
        || host.hasSuffix(".localhost")
}

let marketingVersion = manifestValue(
    ["TUIST_TOASTTY_MOBILE_VERSION", "TOASTTY_MOBILE_VERSION"],
    default: "0.1.0"
)
let buildNumber = manifestValue(
    ["TUIST_TOASTTY_MOBILE_BUILD_NUMBER", "TOASTTY_MOBILE_BUILD_NUMBER"],
    default: "1"
)
let bundleSuffix = sanitizedBundleSuffix(
    manifestValue(
        ["TUIST_TOASTTY_MOBILE_BUNDLE_SUFFIX", "TOASTTY_MOBILE_BUNDLE_SUFFIX"],
        default: ".dev.local"
    )
)
let gatewayURL = optionalManifestValue([
    "TUIST_TOASTTY_MOBILE_GATEWAY_URL",
    "TOASTTY_MOBILE_GATEWAY_URL",
])
let developmentTeam = manifestValue(
    [
        "TUIST_TOASTTY_MOBILE_DEVELOPMENT_TEAM",
        "TOASTTY_IOS_DEVELOPMENT_TEAM",
    ],
    default: "SP7JP8254U"
)
let releaseCodeSignIdentity = optionalManifestValue([
    "TUIST_TOASTTY_MOBILE_RELEASE_CODE_SIGN_IDENTITY",
])
let releaseProvisioningProfile = optionalManifestValue([
    "TUIST_TOASTTY_MOBILE_RELEASE_PROVISIONING_PROFILE_SPECIFIER",
])
let releaseOtherCodeSignFlags = optionalManifestValue([
    "TUIST_TOASTTY_MOBILE_RELEASE_OTHER_CODE_SIGN_FLAGS",
])
let releaseShareExtensionProvisioningProfile = optionalManifestValue([
    "TUIST_TOASTTY_MOBILE_RELEASE_SHARE_EXTENSION_PROVISIONING_PROFILE_SPECIFIER",
])

let productionBundleID = "com.giantthings.toastty.mobile"
let prodTestBundleID = "com.giantthings.toastty.mobile.prodtest"
let fixedDeviceDebugBundleID = "com.giantthings.toastty.mobile.dev"
let usesProdTestIdentity = manifestFlag("TUIST_TOASTTY_MOBILE_PROD_TEST")
let releaseBundleID = usesProdTestIdentity ? prodTestBundleID : productionBundleID
let releaseDisplayName = usesProdTestIdentity ? "Toastty Prod" : "Toastty"
let releaseURLScheme = usesProdTestIdentity ? "toastty-mobile-prodtest" : "toastty-mobile"
let usesFixedDeviceDebugIdentity = manifestFlag("TUIST_TOASTTY_MOBILE_PHYSICAL_DEVICE")
let defaultDebugBundleID = usesFixedDeviceDebugIdentity
    ? fixedDeviceDebugBundleID
    : "\(productionBundleID)\(bundleSuffix)"
let debugBundleID = manifestValue(
    ["TUIST_TOASTTY_MOBILE_BUNDLE_ID", "TOASTTY_MOBILE_BUNDLE_ID"],
    default: defaultDebugBundleID
)
let usesPushProbe = manifestFlag("TUIST_TOASTTY_MOBILE_PUSH_PROBE")
let debugPushRelayURL = optionalManifestValue(["TUIST_TOASTTY_MOBILE_PUSH_RELAY_URL"])
let productionPushRelayURL = optionalManifestValue(["TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL"])
let productionPushRelayID = optionalManifestValue(["TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_ID"])
func validatePushOrigin(_ value: String) {
    guard let url = URLComponents(string: value), url.scheme == "https", url.host?.isEmpty == false,
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          (url.path.isEmpty || url.path == "/"), (url.port == nil || url.port == 443) else {
        fatalError("Push relay must be an HTTPS origin without credentials, query, or path.")
    }
}
if let debugPushRelayURL {
    validatePushOrigin(debugPushRelayURL)
    guard usesFixedDeviceDebugIdentity, debugBundleID == fixedDeviceDebugBundleID,
          !usesProdTestIdentity, !usesPushProbe,
          environment["TUIST_TOASTTY_MOBILE_PUSH_ENVIRONMENT"] == "development" else {
        fatalError("Development notifications require the fixed physical-device identity, explicit development environment, and normal app mode.")
    }
}
if let productionPushRelayURL {
    validatePushOrigin(productionPushRelayURL)
    guard productionPushRelayURL != debugPushRelayURL, !usesProdTestIdentity, !usesPushProbe,
          environment["TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_ENVIRONMENT"] == "production",
          let productionPushRelayID, !productionPushRelayID.isEmpty,
          productionPushRelayID != "toastty-push-dev-v1" else {
        fatalError("Production notifications require a separate production relay ID and explicit production environment.")
    }
}
if usesPushProbe {
    guard usesFixedDeviceDebugIdentity, debugBundleID == fixedDeviceDebugBundleID, !usesProdTestIdentity else {
        fatalError("TUIST_TOASTTY_MOBILE_PUSH_PROBE requires the fixed physical-device Debug identity and cannot use prod-test.")
    }
    for key in ["TOASTTY_IOS_CONFIGURATION", "TOASTTY_NATIVE_DEVICE_BUILD_CONFIGURATION"] {
        if let configuration = environment[key], configuration != "Debug" {
            fatalError("TUIST_TOASTTY_MOBILE_PUSH_PROBE requires Debug configuration.")
        }
    }
}
let enablesComposerTrace = manifestFlag("TUIST_TOASTTY_MOBILE_COMPOSER_TRACE")
let debugDisplayName = enablesComposerTrace
    ? "Toastty Trace"
    : (bundleSuffix == ".dev.local"
        ? "Toastty Dev"
        : "Toastty \((bundleSuffix.split(separator: ".").last ?? "dev").prefix(12))")
let deploymentTarget: DeploymentTargets = .iOS("18.0")

// The share extension hands shared content to the app through an App Group,
// which every signing identity must provision for the app and the extension.
// The TestFlight script turns it off until its distribution profiles do.
let sharesFromOtherApps = manifestFlag("TUIST_TOASTTY_MOBILE_SHARE_EXTENSION", default: true)
let shareExtensionBundleSuffix = ".share"
if sharesFromOtherApps, releaseProvisioningProfile != nil, releaseShareExtensionProvisioningProfile == nil {
    fatalError("Manual Release signing needs TUIST_TOASTTY_MOBILE_RELEASE_SHARE_EXTENSION_PROVISIONING_PROFILE_SPECIFIER for the share extension, or TUIST_TOASTTY_MOBILE_SHARE_EXTENSION=0.")
}

/// Settings the app and its share extension must agree on: one version, one
/// name in the share sheet, and the URL scheme and App Group they hand off by.
let identitySettings: SettingsDictionary = [
    "CURRENT_PROJECT_VERSION": SettingValue(stringLiteral: buildNumber),
    "MARKETING_VERSION": SettingValue(stringLiteral: marketingVersion),
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "TOASTTY_MOBILE_APP_DISPLAY_NAME[config=Debug]": SettingValue(stringLiteral: debugDisplayName),
    "TOASTTY_MOBILE_APP_DISPLAY_NAME[config=Release]": SettingValue(stringLiteral: releaseDisplayName),
    "TOASTTY_MOBILE_APP_GROUP[config=Debug]": SettingValue(stringLiteral: sharesFromOtherApps ? "group.\(debugBundleID)" : ""),
    "TOASTTY_MOBILE_APP_GROUP[config=Release]": SettingValue(stringLiteral: sharesFromOtherApps ? "group.\(releaseBundleID)" : ""),
    "TOASTTY_MOBILE_URL_SCHEME[config=Debug]": "toastty-mobile-dev",
    "TOASTTY_MOBILE_URL_SCHEME[config=Release]": SettingValue(stringLiteral: releaseURLScheme),
]

var appSettings: SettingsDictionary = identitySettings.merging([
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "NO",
    "PRODUCT_BUNDLE_IDENTIFIER[config=Release]": SettingValue(stringLiteral: releaseBundleID),
    "PRODUCT_MODULE_NAME": "ToasttyMobileApp",
    "TOASTTY_COMPOSER_TRACE_ENABLED[config=Debug]": enablesComposerTrace ? "YES" : "NO",
    "TOASTTY_COMPOSER_TRACE_ENABLED[config=Release]": "NO",
]) { _, appValue in appValue }

appSettings["CODE_SIGN_STYLE"] = "Automatic"
appSettings["DEVELOPMENT_TEAM"] = SettingValue(stringLiteral: developmentTeam)
if sharesFromOtherApps {
    appSettings["CODE_SIGN_ENTITLEMENTS"] = "Entitlements/AppGroup.entitlements"
}
if usesPushProbe {
    // Keep the APNs receiver and development entitlement out of Release even
    // when both configurations come from this same generated project.
    appSettings["SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Debug]"] = "$(inherited) DEBUG TOASTTY_MOBILE_PUSH_PROBE"
    appSettings["CODE_SIGN_ENTITLEMENTS[config=Debug]"] = sharesFromOtherApps
        ? "Entitlements/PushDevelopmentAppGroup.entitlements"
        : "Entitlements/PushProbe.entitlements"
}
if debugPushRelayURL != nil {
    appSettings["CODE_SIGN_ENTITLEMENTS[config=Debug]"] = sharesFromOtherApps
        ? "Entitlements/PushDevelopmentAppGroup.entitlements"
        : "Entitlements/PushDevelopment.entitlements"
}
if productionPushRelayURL != nil {
    appSettings["CODE_SIGN_ENTITLEMENTS[config=Release]"] = sharesFromOtherApps
        ? "Entitlements/PushProductionAppGroup.entitlements"
        : "Entitlements/PushProduction.entitlements"
}
appSettings["TOASTTY_MOBILE_PUSH_RELAY_URL[config=Debug]"] = SettingValue(stringLiteral: debugPushRelayURL ?? "")
appSettings["TOASTTY_MOBILE_PUSH_RELAY_URL[config=Release]"] = SettingValue(stringLiteral: productionPushRelayURL ?? "")
appSettings["TOASTTY_MOBILE_PUSH_RELAY_ID[config=Debug]"] = SettingValue(stringLiteral: debugPushRelayURL == nil ? "" : "toastty-push-dev-v1")
appSettings["TOASTTY_MOBILE_PUSH_RELAY_ID[config=Release]"] = SettingValue(stringLiteral: productionPushRelayURL == nil ? "" : productionPushRelayID ?? "")
appSettings["TOASTTY_MOBILE_PUSH_ENVIRONMENT[config=Debug]"] = SettingValue(stringLiteral: debugPushRelayURL == nil ? "" : "development")
appSettings["TOASTTY_MOBILE_PUSH_ENVIRONMENT[config=Release]"] = SettingValue(stringLiteral: productionPushRelayURL == nil ? "" : "production")
if let releaseProvisioningProfile {
    appSettings["CODE_SIGN_STYLE[config=Release]"] = "Manual"
    appSettings["PROVISIONING_PROFILE_SPECIFIER[config=Release]"] = SettingValue(stringLiteral: releaseProvisioningProfile)
}
if let releaseCodeSignIdentity {
    appSettings["CODE_SIGN_IDENTITY[config=Release]"] = SettingValue(stringLiteral: releaseCodeSignIdentity)
}
if let releaseOtherCodeSignFlags {
    appSettings["OTHER_CODE_SIGN_FLAGS[config=Release]"] = SettingValue(stringLiteral: releaseOtherCodeSignFlags)
}

var appInfoPlist: [String: Plist.Value] = [
    "CFBundleDisplayName": .string("$(TOASTTY_MOBILE_APP_DISPLAY_NAME)"),
    "CFBundleIconName": .string("AppIcon"),
    "CFBundleName": .string("$(TOASTTY_MOBILE_APP_DISPLAY_NAME)"),
    "CFBundleShortVersionString": .string("$(MARKETING_VERSION)"),
    "CFBundleURLTypes": .array([
        .dictionary([
            "CFBundleURLName": .string("com.giantthings.toastty.mobile.routing"),
            "CFBundleURLSchemes": .array([.string("$(TOASTTY_MOBILE_URL_SCHEME)")]),
        ]),
    ]),
    "CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)"),
    "ToasttyMobileAppGroup": .string("$(TOASTTY_MOBILE_APP_GROUP)"),
    "ToasttyMobilePushRelayURL": .string("$(TOASTTY_MOBILE_PUSH_RELAY_URL)"),
    "ToasttyMobilePushRelayID": .string("$(TOASTTY_MOBILE_PUSH_RELAY_ID)"),
    "ToasttyMobilePushEnvironment": .string("$(TOASTTY_MOBILE_PUSH_ENVIRONMENT)"),
    "ToasttyComposerTraceEnabled": .string("$(TOASTTY_COMPOSER_TRACE_ENABLED)"),
    "ITSAppUsesNonExemptEncryption": .boolean(false),
    "NSCameraUsageDescription": .string("Toastty uses the camera to take photos for messages and scan a pairing code shown by your Mac."),
    "NSLocalNetworkUsageDescription": .string("Toastty connects to a local development gateway when local mode is enabled."),
    "UILaunchScreen": .dictionary([:]),
    // The palette in ToasttyDesignTokens is dark-only; forcing dark here keeps
    // UIKit-managed chrome (alerts, keyboard, sheets) consistent with it.
    "UIUserInterfaceStyle": .string("Dark"),
    "UISupportedInterfaceOrientations": .array([.string("UIInterfaceOrientationPortrait")]),
]

if let gatewayURL {
    appInfoPlist["ToasttyMobileGatewayURL"] = .string(gatewayURL)
}
if localHTTPAllowed(for: gatewayURL) {
    appInfoPlist["NSAppTransportSecurity"] = .dictionary([
        "NSAllowsLocalNetworking": .boolean(true),
    ])
}

var shareExtensionSettings: SettingsDictionary = identitySettings.merging([
    "CODE_SIGN_ENTITLEMENTS": "Entitlements/AppGroup.entitlements",
    "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": SettingValue(stringLiteral: developmentTeam),
    "PRODUCT_BUNDLE_IDENTIFIER[config=Release]": SettingValue(
        stringLiteral: "\(releaseBundleID)\(shareExtensionBundleSuffix)"
    ),
    "PRODUCT_MODULE_NAME": "ToasttyMobileShareExtension",
]) { _, extensionValue in extensionValue }
// The extension has its own App Store profile, so Release signs it with the
// app's identity and keychain but that profile.
if let releaseShareExtensionProvisioningProfile {
    shareExtensionSettings["CODE_SIGN_STYLE[config=Release]"] = "Manual"
    shareExtensionSettings["PROVISIONING_PROFILE_SPECIFIER[config=Release]"] = SettingValue(
        stringLiteral: releaseShareExtensionProvisioningProfile
    )
}
if let releaseCodeSignIdentity {
    shareExtensionSettings["CODE_SIGN_IDENTITY[config=Release]"] = SettingValue(stringLiteral: releaseCodeSignIdentity)
}
if let releaseOtherCodeSignFlags {
    shareExtensionSettings["OTHER_CODE_SIGN_FLAGS[config=Release]"] = SettingValue(stringLiteral: releaseOtherCodeSignFlags)
}

let shareExtensionTargets: [Target] = sharesFromOtherApps ? [
    .target(
        name: "ToasttyMobileShareExtension",
        destinations: .iOS,
        product: .appExtension,
        productName: "ToasttyShare",
        bundleId: "\(debugBundleID)\(shareExtensionBundleSuffix)",
        deploymentTargets: deploymentTarget,
        infoPlist: .extendingDefault(with: [
            "CFBundleDisplayName": .string("$(TOASTTY_MOBILE_APP_DISPLAY_NAME)"),
            "CFBundleShortVersionString": .string("$(MARKETING_VERSION)"),
            "CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)"),
            "ToasttyMobileAppGroup": .string("$(TOASTTY_MOBILE_APP_GROUP)"),
            "ToasttyMobileURLScheme": .string("$(TOASTTY_MOBILE_URL_SCHEME)"),
            "UIUserInterfaceStyle": .string("Dark"),
            "NSExtension": .dictionary([
                "NSExtensionPointIdentifier": .string("com.apple.share-services"),
                "NSExtensionPrincipalClass": .string("$(PRODUCT_MODULE_NAME).ToasttyShareViewController"),
                "NSExtensionAttributes": .dictionary([
                    // Counts above the Mac's four-file limit keep Toastty in
                    // the share sheet for a larger selection; the draft takes
                    // the first four and says what it left out.
                    "NSExtensionActivationRule": .dictionary([
                        "NSExtensionActivationSupportsImageWithMaxCount": .integer(10),
                        "NSExtensionActivationSupportsFileWithMaxCount": .integer(10),
                        "NSExtensionActivationSupportsWebURLWithMaxCount": .integer(1),
                        "NSExtensionActivationSupportsText": .boolean(true),
                    ]),
                ]),
            ]),
        ]),
        sources: [
            "Sources/ToasttyMobileShareExtension/**",
            "Sources/ToasttyMobileShared/**",
        ],
        dependencies: [.target(name: "RemoteProtocol")],
        settings: .settings(base: shareExtensionSettings)
    ),
] : []

let project = Project(
    name: "ToasttyMobile",
    settings: .settings(base: [
        "CLANG_ANALYZER_LOCALIZABILITY_NONLOCALIZED": "YES",
        "SWIFT_VERSION": "6.0",
        "SWIFT_STRICT_CONCURRENCY": "complete",
    ]),
    targets: [
        .target(
            name: "RemoteProtocol",
            destinations: .iOS,
            product: .staticFramework,
            bundleId: "com.giantthings.toastty.mobile.remote-protocol",
            deploymentTargets: deploymentTarget,
            infoPlist: .default,
            sources: ["../Sources/RemoteProtocol/**"],
            settings: .settings(base: [
                "SWIFT_VERSION": "6.0",
                "SWIFT_STRICT_CONCURRENCY": "complete",
            ])
        ),
        .target(
            name: "ToasttyMobileApp",
            destinations: .iOS,
            product: .app,
            productName: "Toastty",
            bundleId: debugBundleID,
            deploymentTargets: deploymentTarget,
            infoPlist: .extendingDefault(with: appInfoPlist),
            sources: [
                "Sources/ToasttyMobileApp/**",
                "Sources/ToasttyMobileShared/**",
            ],
            resources: [
                "Resources/ToasttyMobileApp/**",
                .folderReference(path: "../Sources/App/Resources/WebPanels/local-document-panel"),
                .folderReference(path: "../Sources/App/Resources/WebPanels/scratchpad-panel"),
            ],
            dependencies: [
                .target(name: "ToasttyMobileDomain"),
                .target(name: "RemoteProtocol"),
            ] + shareExtensionTargets.map { .target(name: $0.name) },
            settings: .settings(base: appSettings)
        ),
        .target(
            name: "ToasttyMobileDomain",
            destinations: .iOS,
            product: .staticFramework,
            bundleId: "com.giantthings.toastty.mobile.domain",
            deploymentTargets: deploymentTarget,
            infoPlist: .default,
            sources: ["Sources/ToasttyMobileDomain/**"],
            dependencies: [.target(name: "RemoteProtocol")]
        ),
        .target(
            name: "ToasttyMobileDomainTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.giantthings.toastty.mobile.domain.tests",
            deploymentTargets: deploymentTarget,
            infoPlist: .default,
            sources: ["Tests/ToasttyMobileDomainTests/**"],
            resources: [
                .folderReference(path: "../Tests/RemoteProtocol/Fixtures/v1"),
                .folderReference(path: "Tests/ToasttyMobileDomainTests/Fixtures/Compatibility"),
            ],
            dependencies: [
                .target(name: "ToasttyMobileDomain"),
                .target(name: "RemoteProtocol"),
            ]
        ),
        .target(
            name: "ToasttyMobileAppTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.giantthings.toastty.mobile.app.tests",
            deploymentTargets: deploymentTarget,
            infoPlist: .default,
            sources: ["Tests/ToasttyMobileAppTests/**"],
            dependencies: [
                .target(name: "ToasttyMobileApp"),
                .target(name: "ToasttyMobileDomain"),
            ]
        ),
        .target(
            name: "ToasttyMobileUITests",
            destinations: .iOS,
            product: .uiTests,
            bundleId: "com.giantthings.toastty.mobile.ui-tests",
            deploymentTargets: deploymentTarget,
            infoPlist: .default,
            sources: ["Tests/ToasttyMobileUITests/**"],
            dependencies: [.target(name: "ToasttyMobileApp")]
        ),
    ] + shareExtensionTargets,
    schemes: [
        .scheme(
            name: "ToasttyMobileApp",
            buildAction: .buildAction(targets: [
                .project(path: .relativeToRoot("."), target: "ToasttyMobileApp"),
            ]),
            testAction: .targets([
                .testableTarget(target: .target("ToasttyMobileDomainTests")),
                .testableTarget(target: .target("ToasttyMobileAppTests")),
                .testableTarget(target: .target("ToasttyMobileUITests")),
            ]),
            runAction: .runAction(
                configuration: .debug,
                executable: .project(path: .relativeToRoot("."), target: "ToasttyMobileApp")
            ),
            archiveAction: .archiveAction(configuration: .release)
        ),
        .scheme(
            name: "ToasttyMobileApp-Fixture",
            buildAction: .buildAction(targets: [
                .project(path: .relativeToRoot("."), target: "ToasttyMobileApp"),
            ]),
            runAction: .runAction(
                configuration: .debug,
                executable: .project(path: .relativeToRoot("."), target: "ToasttyMobileApp"),
                arguments: .arguments(environmentVariables: [
                    "TOASTTY_MOBILE_USE_FIXTURE": .environmentVariable(value: "1", isEnabled: true),
                ])
            )
        ),
        .scheme(
            name: "ToasttyMobileApp-Release",
            buildAction: .buildAction(targets: [
                .project(path: .relativeToRoot("."), target: "ToasttyMobileApp"),
            ]),
            // Release tests do not use the Debug fixture UI bundle.
            testAction: .targets([
                .testableTarget(target: .target("ToasttyMobileDomainTests")),
                .testableTarget(target: .target("ToasttyMobileAppTests")),
            ], configuration: .release),
            runAction: .runAction(
                configuration: .release,
                executable: .project(path: .relativeToRoot("."), target: "ToasttyMobileApp")
            ),
            archiveAction: .archiveAction(configuration: .release)
        ),
    ]
)
