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

func manifestFlag(_ key: String) -> Bool {
    guard let value = environment[key] else { return false }
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
let debugDisplayName = bundleSuffix == ".dev.local"
    ? "Toastty Dev"
    : "Toastty \((bundleSuffix.split(separator: ".").last ?? "dev").prefix(12))"
let deploymentTarget: DeploymentTargets = .iOS("18.0")

var appSettings: SettingsDictionary = [
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "NO",
    "CURRENT_PROJECT_VERSION": SettingValue(stringLiteral: buildNumber),
    "MARKETING_VERSION": SettingValue(stringLiteral: marketingVersion),
    "PRODUCT_BUNDLE_IDENTIFIER[config=Release]": SettingValue(stringLiteral: releaseBundleID),
    "PRODUCT_MODULE_NAME": "ToasttyMobileApp",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "TOASTTY_MOBILE_APP_DISPLAY_NAME[config=Debug]": SettingValue(stringLiteral: debugDisplayName),
    "TOASTTY_MOBILE_APP_DISPLAY_NAME[config=Release]": SettingValue(stringLiteral: releaseDisplayName),
    "TOASTTY_MOBILE_URL_SCHEME[config=Debug]": "toastty-mobile-dev",
    "TOASTTY_MOBILE_URL_SCHEME[config=Release]": SettingValue(stringLiteral: releaseURLScheme),
]

appSettings["CODE_SIGN_STYLE"] = "Automatic"
appSettings["DEVELOPMENT_TEAM"] = SettingValue(stringLiteral: developmentTeam)
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
    "ITSAppUsesNonExemptEncryption": .boolean(false),
    "NSCameraUsageDescription": .string("Toastty scans a pairing code shown by your Mac."),
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
            sources: ["Sources/ToasttyMobileApp/**"],
            resources: [
                "Resources/ToasttyMobileApp/**",
                .folderReference(path: "../Sources/App/Resources/WebPanels/local-document-panel"),
                .folderReference(path: "../Sources/App/Resources/WebPanels/scratchpad-panel"),
            ],
            dependencies: [
                .target(name: "ToasttyMobileDomain"),
                .target(name: "RemoteProtocol"),
            ],
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
    ],
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
            runAction: .runAction(
                configuration: .release,
                executable: .project(path: .relativeToRoot("."), target: "ToasttyMobileApp")
            ),
            archiveAction: .archiveAction(configuration: .release)
        ),
    ]
)
