import ProjectDescription
import Foundation

let ghosttyDebugXCFrameworkRelativePath = "Dependencies/GhosttyKit.Debug.xcframework"
let ghosttyReleaseXCFrameworkRelativePath = "Dependencies/GhosttyKit.Release.xcframework"
let environment = ProcessInfo.processInfo.environment
// Fail fast if both the manifest-visible and compatibility env names are set
// but disagree, so release metadata cannot silently drift during generation.
func resolvedManifestEnvironmentValue(
    manifestKey: String,
    compatibilityKey: String,
    defaultValue: String
) -> String {
    let manifestValue = environment[manifestKey]
    let compatibilityValue = environment[compatibilityKey]

    if let manifestValue, manifestValue.isEmpty {
        fatalError("\(manifestKey) must not be empty when set at `tuist generate` time.")
    }
    if let compatibilityValue, compatibilityValue.isEmpty {
        fatalError("\(compatibilityKey) must not be empty when set at `tuist generate` time.")
    }
    if
        let manifestValue,
        let compatibilityValue,
        manifestValue != compatibilityValue
    {
        fatalError("\(manifestKey) and \(compatibilityKey) must match when both are set at `tuist generate` time.")
    }

    return manifestValue ?? compatibilityValue ?? defaultValue
}

// Tuist manifest evaluation reliably exposes TUIST_* variables. Keep the plain
// TOASTTY_* names as a compatibility fallback for contexts where they still pass through.
let marketingVersion = resolvedManifestEnvironmentValue(
    manifestKey: "TUIST_TOASTTY_VERSION",
    compatibilityKey: "TOASTTY_VERSION",
    defaultValue: "0.1.0"
)
let buildNumber = resolvedManifestEnvironmentValue(
    manifestKey: "TUIST_TOASTTY_BUILD_NUMBER",
    compatibilityKey: "TOASTTY_BUILD_NUMBER",
    defaultValue: "1"
)
let sparkleFeedURL = "https://updates.toastty.dev/appcast.xml"
let sparklePublicEDKey = "TmgFEcjPjqplsktNMX2rJSj+2YjJyVX5UvGMvSBHjlM="
// Repo-local toggle consumed by Project.swift, not a Tuist built-in.
let distributionSigning = environment["TUIST_DISTRIBUTION_SIGNING"] == "1"
let ghosttyMacOSSliceDirectoryCandidates = [
    "macos-arm64_x86_64",
    "macos-arm64",
    "macos-x86_64",
]
let ghosttyStaticLibraryFilenameCandidates = [
    "libghostty.a",
    "libghostty-fat.a",
]
let ghosttyIntegrationDisabled = {
    // Tuist manifest evaluation reliably exposes TUIST_* env vars; keep TOASTTY_* as best-effort compatibility.
    return environment["TUIST_DISABLE_GHOSTTY"] == "1"
        || environment["TOASTTY_DISABLE_GHOSTTY"] == "1"
}()
let manifestRootPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .path
let workingDirectoryRootPath = FileManager.default.currentDirectoryPath
func ghosttyPathExists(relativePath: String) -> Bool {
    let candidatePaths = [
        "\(manifestRootPath)/\(relativePath)",
        "\(workingDirectoryRootPath)/\(relativePath)",
    ]

    return candidatePaths.contains { FileManager.default.fileExists(atPath: $0) }
}

struct GhosttyLibrarySelection {
    let sliceRelativePath: String
    let libraryRelativePath: String
}

func resolveGhosttyLibrarySelection(xcframeworkRelativePath: String) -> GhosttyLibrarySelection? {
    for sliceDirectory in ghosttyMacOSSliceDirectoryCandidates {
        let sliceRelativePath = "\(xcframeworkRelativePath)/\(sliceDirectory)"
        let moduleMapRelativePath = "\(sliceRelativePath)/Headers/module.modulemap"

        guard ghosttyPathExists(relativePath: moduleMapRelativePath) else {
            continue
        }

        for libraryFilename in ghosttyStaticLibraryFilenameCandidates {
            let libraryRelativePath = "\(sliceRelativePath)/\(libraryFilename)"
            if ghosttyPathExists(relativePath: libraryRelativePath) {
                return GhosttyLibrarySelection(
                    sliceRelativePath: sliceRelativePath,
                    libraryRelativePath: libraryRelativePath
                )
            }
        }
    }

    return nil
}

let ghosttyDebugVariantSelection = resolveGhosttyLibrarySelection(
    xcframeworkRelativePath: ghosttyDebugXCFrameworkRelativePath
)
let ghosttyReleaseVariantSelection = resolveGhosttyLibrarySelection(
    xcframeworkRelativePath: ghosttyReleaseXCFrameworkRelativePath
)
let ghosttyDebugSelection = ghosttyDebugVariantSelection ?? ghosttyReleaseVariantSelection
let ghosttyReleaseSelection = ghosttyReleaseVariantSelection ?? ghosttyDebugVariantSelection
let hasGhosttyXCFrameworkArtifact = ghosttyDebugSelection != nil && ghosttyReleaseSelection != nil
let hasGhosttyXCFramework = hasGhosttyXCFrameworkArtifact && !ghosttyIntegrationDisabled

func applyGhosttyVariantModuleSettings(
    configurationName: String,
    sliceRelativePath: String,
    settings: inout SettingsDictionary
) {
    let headersPath = "$(SRCROOT)/\(sliceRelativePath)/Headers"
    let moduleMapPath = "\(headersPath)/module.modulemap"

    settings["HEADER_SEARCH_PATHS[config=\(configurationName)]"] = .array([
        "$(inherited)",
        headersPath,
    ])
    settings["OTHER_SWIFT_FLAGS[config=\(configurationName)]"] = .array([
        "$(inherited)",
        "-Xcc",
        "-fmodule-map-file=\(moduleMapPath)",
    ])
}

func applyGhosttyVariantLinkSettings(
    configurationName: String,
    sliceRelativePath: String,
    libraryRelativePath: String,
    settings: inout SettingsDictionary
) {
    applyGhosttyVariantModuleSettings(
        configurationName: configurationName,
        sliceRelativePath: sliceRelativePath,
        settings: &settings
    )

    let libraryPath = "$(SRCROOT)/\(libraryRelativePath)"
    settings["OTHER_LDFLAGS[config=\(configurationName)]"] = .array([
        "$(inherited)",
        libraryPath,
    ])
}

var appDependencies: [TargetDependency] = [
    .target(name: "CoreState"),
    .external(name: "Sparkle"),
]

var appTestTargetSettingsBase: SettingsDictionary = [
    "CODE_SIGNING_ALLOWED": "YES",
]
// Apple Development signing is required for UNUserNotificationCenter — macOS won't
// register unsigned or ad-hoc signed apps in the Notifications preferences pane.
// The project-level CODE_SIGNING_ALLOWED=NO is intentional for framework/test targets;
// we override it here for the app target only.
// Set TUIST_DEVELOPMENT_TEAM env var at `tuist generate` time for Apple Development
// signing (required for UNUserNotificationCenter). Falls back to ad-hoc when unset.
let developmentTeam = environment["TUIST_DEVELOPMENT_TEAM"]
if distributionSigning && developmentTeam == nil {
    fatalError("TUIST_DISTRIBUTION_SIGNING=1 requires TUIST_DEVELOPMENT_TEAM to be set at `tuist generate` time.")
}

var appTargetSettingsBase: SettingsDictionary = [
    "CODE_SIGNING_ALLOWED": "YES",
    // Child processes launched from Toastty inherit the host app's TCC identity
    // for terminal-style prompts, so the app bundle needs explicit camera/mic
    // entitlements in addition to the usage descriptions below.
    "CODE_SIGN_ENTITLEMENTS": "Tuist/Toastty.entitlements",
    "MARKETING_VERSION": SettingValue(stringLiteral: marketingVersion),
    "CURRENT_PROJECT_VERSION": SettingValue(stringLiteral: buildNumber),
    "ENABLE_HARDENED_RUNTIME[config=Debug]": "NO",
    "ENABLE_HARDENED_RUNTIME[config=Release]": distributionSigning ? "YES" : "NO",
    // Keep the Swift module name as "ToasttyApp" even though the product is "Toastty",
    // so @testable import ToasttyApp and the struct ToasttyApp: App name stay consistent.
    "PRODUCT_MODULE_NAME": "ToasttyApp",
]
if let developmentTeam {
    appTargetSettingsBase["DEVELOPMENT_TEAM"] = SettingValue(stringLiteral: developmentTeam)
    appTargetSettingsBase["CODE_SIGN_IDENTITY[config=Debug]"] = "Apple Development"
    appTargetSettingsBase["CODE_SIGN_STYLE[config=Debug]"] = "Automatic"
    if distributionSigning {
        appTargetSettingsBase["CODE_SIGN_IDENTITY[config=Release]"] = "Developer ID Application"
        appTargetSettingsBase["CODE_SIGN_STYLE[config=Release]"] = "Manual"
        appTargetSettingsBase["PROVISIONING_PROFILE_SPECIFIER[config=Release]"] = ""
    } else {
        appTargetSettingsBase["CODE_SIGN_IDENTITY[config=Release]"] = "Apple Development"
        appTargetSettingsBase["CODE_SIGN_STYLE[config=Release]"] = "Automatic"
    }

    appTestTargetSettingsBase["DEVELOPMENT_TEAM"] = SettingValue(stringLiteral: developmentTeam)
    appTestTargetSettingsBase["CODE_SIGN_IDENTITY[config=Debug]"] = "Apple Development"
    appTestTargetSettingsBase["CODE_SIGN_STYLE[config=Debug]"] = "Automatic"
    appTestTargetSettingsBase["CODE_SIGN_IDENTITY[config=Release]"] = "Apple Development"
    appTestTargetSettingsBase["CODE_SIGN_STYLE[config=Release]"] = "Automatic"
} else {
    appTargetSettingsBase["CODE_SIGN_IDENTITY"] = "-"
    appTestTargetSettingsBase["CODE_SIGN_IDENTITY"] = "-"
}
var appTestDependencies: [TargetDependency] = [
    .target(name: "ToasttyApp"),
    .target(name: "CoreState"),
]

if hasGhosttyXCFramework {
    if
        let ghosttyDebugSelection,
        let ghosttyReleaseSelection
    {
        // Tuist validates dependency paths during manifest loading, so selecting
        // config-specific artifacts is handled through per-config linker/module-map settings.
        applyGhosttyVariantLinkSettings(
            configurationName: "Debug",
            sliceRelativePath: ghosttyDebugSelection.sliceRelativePath,
            libraryRelativePath: ghosttyDebugSelection.libraryRelativePath,
            settings: &appTargetSettingsBase
        )
        applyGhosttyVariantLinkSettings(
            configurationName: "Release",
            sliceRelativePath: ghosttyReleaseSelection.sliceRelativePath,
            libraryRelativePath: ghosttyReleaseSelection.libraryRelativePath,
            settings: &appTargetSettingsBase
        )
        applyGhosttyVariantLinkSettings(
            configurationName: "Debug",
            sliceRelativePath: ghosttyDebugSelection.sliceRelativePath,
            libraryRelativePath: ghosttyDebugSelection.libraryRelativePath,
            settings: &appTestTargetSettingsBase
        )
        applyGhosttyVariantLinkSettings(
            configurationName: "Release",
            sliceRelativePath: ghosttyReleaseSelection.sliceRelativePath,
            libraryRelativePath: ghosttyReleaseSelection.libraryRelativePath,
            settings: &appTestTargetSettingsBase
        )
    }
    appTargetSettingsBase["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) TOASTTY_HAS_GHOSTTY_KIT"
    appTestTargetSettingsBase["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) TOASTTY_HAS_GHOSTTY_KIT"
    // Ghostty's static archive includes C++ objects and macOS text-input symbols.
    appTargetSettingsBase["OTHER_LDFLAGS"] = .array([
        "$(inherited)",
        "-lc++",
        "-framework",
        "Carbon",
    ])
    appTestTargetSettingsBase["OTHER_LDFLAGS"] = .array([
        "$(inherited)",
        "-lc++",
        "-framework",
        "Carbon",
    ])
    appTestTargetSettingsBase["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) TOASTTY_HAS_GHOSTTY_KIT"
}

let appTargetSettings: Settings = .settings(base: appTargetSettingsBase)
let appTestTargetSettings: Settings = .settings(base: appTestTargetSettingsBase)

let project = Project(
    name: "toastty",
    settings: .settings(
        base: [
            "CODE_SIGNING_ALLOWED": "NO",
            "SWIFT_VERSION": "6.0",
        ]
    ),
    targets: [
        .target(
            name: "ToasttyApp",
            destinations: .macOS,
            product: .app,
            productName: "Toastty",
            bundleId: "com.GiantThings.toastty",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": .string("$(MARKETING_VERSION)"),
                "CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)"),
                "LSApplicationCategoryType": .string("public.app-category.developer-tools"),
                "LSMinimumSystemVersion": .string("14.0"),
                "NSCameraUsageDescription": .string("A program running within Toastty would like to use the camera."),
                "NSHumanReadableCopyright": .string("Copyright © 2026 Vishal Kapur. All rights reserved."),
                "NSMicrophoneUsageDescription": .string("A program running within Toastty would like to use your microphone."),
                "SUFeedURL": .string(sparkleFeedURL),
                "SUPublicEDKey": .string(sparklePublicEDKey),
            ]),
            sources: ["Sources/App/**"],
            resources: ["Sources/App/Resources/**"],
            dependencies: appDependencies,
            settings: appTargetSettings
        ),
        .target(
            name: "CoreState",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "com.GiantThings.toastty.core",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Sources/Core/**"]
        ),
        .target(
            name: "ToasttyCLIKit",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "com.GiantThings.toastty.clikit",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Sources/CLIKit/**"],
            dependencies: [
                .target(name: "CoreState"),
            ]
        ),
        .target(
            name: "toastty",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "com.GiantThings.toastty.cli",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Sources/CLI/**"],
            dependencies: [
                .target(name: "ToasttyCLIKit"),
            ]
        ),
        .target(
            name: "toastty-agent-shim",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "com.GiantThings.toastty.agent-shim",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Sources/AgentShim/**"],
            dependencies: [
                .target(name: "CoreState"),
            ]
        ),
        .target(
            name: "CoreStateTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.GiantThings.toastty.core.tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Tests/Core/**"],
            dependencies: [
                .target(name: "CoreState"),
            ]
        ),
        .target(
            name: "ToasttyCLITests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.GiantThings.toastty.cli.tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Tests/CLI/**"],
            dependencies: [
                .target(name: "ToasttyCLIKit"),
            ]
        ),
        .target(
            name: "ToasttyAppTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.GiantThings.toastty.app.tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Tests/App/**"],
            dependencies: appTestDependencies,
            settings: appTestTargetSettings
        ),
    ],
    schemes: [
        .scheme(
            name: "ToasttyApp",
            buildAction: .buildAction(
                targets: [
                    .project(path: .relativeToRoot("."), target: "ToasttyApp"),
                    .project(path: .relativeToRoot("."), target: "toastty"),
                    .project(path: .relativeToRoot("."), target: "toastty-agent-shim"),
                ]
            ),
            testAction: .targets(
                [
                    .testableTarget(target: .target("CoreStateTests")),
                    .testableTarget(target: .target("ToasttyCLITests")),
                    .testableTarget(target: .target("ToasttyAppTests")),
                ]
            ),
            runAction: .runAction(
                executable: .project(path: .relativeToRoot("."), target: "ToasttyApp"),
                arguments: .arguments(
                    environmentVariables: [
                        "TOASTTY_DEV_WORKTREE_ROOT": .environmentVariable(value: "$(SRCROOT)", isEnabled: true),
                        "TOASTTY_LOG_LEVEL": .environmentVariable(value: "debug", isEnabled: true),
                    ]
                )
            )
        ),
        .scheme(
            name: "ToasttyApp-Release",
            buildAction: .buildAction(
                targets: [
                    .project(path: .relativeToRoot("."), target: "ToasttyApp"),
                    .project(path: .relativeToRoot("."), target: "toastty"),
                    .project(path: .relativeToRoot("."), target: "toastty-agent-shim"),
                ]
            ),
            runAction: .runAction(
                configuration: .release,
                executable: .project(path: .relativeToRoot("."), target: "ToasttyApp"),
                arguments: .arguments(
                    environmentVariables: [
                        "TOASTTY_DEV_WORKTREE_ROOT": .environmentVariable(value: "$(SRCROOT)", isEnabled: true),
                    ]
                )
            ),
            archiveAction: .archiveAction(
                configuration: .release
            )
        ),
    ],
)
