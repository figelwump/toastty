import ProjectDescription
import Foundation

let ghosttyLegacyXCFrameworkRelativePath = "Dependencies/GhosttyKit.xcframework"
let ghosttyDebugXCFrameworkRelativePath = "Dependencies/GhosttyKit.Debug.xcframework"
let ghosttyReleaseXCFrameworkRelativePath = "Dependencies/GhosttyKit.Release.xcframework"
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
    let environment = ProcessInfo.processInfo.environment
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
let ghosttyLegacySelection = resolveGhosttyLibrarySelection(
    xcframeworkRelativePath: ghosttyLegacyXCFrameworkRelativePath
)
let ghosttyDebugSelection = ghosttyDebugVariantSelection ?? ghosttyLegacySelection ?? ghosttyReleaseVariantSelection
let ghosttyReleaseSelection = ghosttyReleaseVariantSelection ?? ghosttyLegacySelection ?? ghosttyDebugVariantSelection
let hasGhosttyVariantLinkSettings = ghosttyDebugSelection != nil && ghosttyReleaseSelection != nil
let hasGhosttyLegacyXCFrameworkArtifact = ghosttyPathExists(
    relativePath: ghosttyLegacyXCFrameworkRelativePath
)
let hasGhosttyXCFrameworkArtifact = hasGhosttyVariantLinkSettings || hasGhosttyLegacyXCFrameworkArtifact
let hasGhosttyXCFramework = hasGhosttyXCFrameworkArtifact && !ghosttyIntegrationDisabled

func applyGhosttyVariantLinkSettings(
    configurationName: String,
    sliceRelativePath: String,
    libraryRelativePath: String,
    settings: inout SettingsDictionary
) {
    let headersPath = "$(SRCROOT)/\(sliceRelativePath)/Headers"
    let moduleMapPath = "\(headersPath)/module.modulemap"
    let libraryPath = "$(SRCROOT)/\(libraryRelativePath)"

    settings["HEADER_SEARCH_PATHS[config=\(configurationName)]"] = .array([
        "$(inherited)",
        headersPath,
    ])
    settings["OTHER_SWIFT_FLAGS[config=\(configurationName)]"] = .array([
        "$(inherited)",
        "-Xcc",
        "-fmodule-map-file=\(moduleMapPath)",
    ])
    settings["OTHER_LDFLAGS[config=\(configurationName)]"] = .array([
        "$(inherited)",
        libraryPath,
    ])
}

var appDependencies: [TargetDependency] = [
    .target(name: "CoreState"),
]

var appTestTargetSettingsBase: SettingsDictionary = [:]

// Apple Development signing is required for UNUserNotificationCenter — macOS won't
// register unsigned or ad-hoc signed apps in the Notifications preferences pane.
// The project-level CODE_SIGNING_ALLOWED=NO is intentional for framework/test targets;
// we override it here for the app target only.
// Set TUIST_DEVELOPMENT_TEAM env var at `tuist generate` time for Apple Development
// signing (required for UNUserNotificationCenter). Falls back to ad-hoc when unset.
let developmentTeam = ProcessInfo.processInfo.environment["TUIST_DEVELOPMENT_TEAM"]
var appTargetSettingsBase: SettingsDictionary = [
    "CODE_SIGNING_ALLOWED": "YES",
]
if let developmentTeam {
    appTargetSettingsBase["CODE_SIGN_IDENTITY"] = "Apple Development"
    appTargetSettingsBase["CODE_SIGN_STYLE"] = "Automatic"
    appTargetSettingsBase["DEVELOPMENT_TEAM"] = SettingValue(stringLiteral: developmentTeam)
} else {
    appTargetSettingsBase["CODE_SIGN_IDENTITY"] = "-"
}

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
    } else {
        appDependencies.append(.xcframework(path: .relativeToRoot(ghosttyLegacyXCFrameworkRelativePath)))
    }
    appTargetSettingsBase["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) TOASTTY_HAS_GHOSTTY_KIT"
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
            bundleId: "com.GiantThings.toastty",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Sources/App/**"],
            dependencies: appDependencies,
            settings: appTargetSettings
        ),
        .target(
            name: "CoreState",
            destinations: .macOS,
            product: .framework,
            bundleId: "com.GiantThings.toastty.core",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Sources/Core/**"]
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
            name: "ToasttyAppTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.GiantThings.toastty.app.tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Tests/App/**"],
            dependencies: [
                .target(name: "ToasttyApp"),
                .target(name: "CoreState"),
            ],
            settings: appTestTargetSettings
        ),
    ],
    schemes: [
        .scheme(
            name: "ToasttyApp",
            buildAction: .buildAction(
                targets: [
                    .project(path: .relativeToRoot("."), target: "ToasttyApp"),
                ]
            ),
            testAction: .targets(
                [
                    .testableTarget(target: .target("CoreStateTests")),
                    .testableTarget(target: .target("ToasttyAppTests")),
                ]
            ),
            runAction: .runAction(
                executable: .project(path: .relativeToRoot("."), target: "ToasttyApp"),
                arguments: .arguments(
                    environmentVariables: [
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
                ]
            ),
            runAction: .runAction(
                configuration: .release,
                executable: .project(path: .relativeToRoot("."), target: "ToasttyApp")
            ),
            archiveAction: .archiveAction(
                configuration: .release
            )
        ),
    ],
)
