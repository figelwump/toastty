import ProjectDescription
import Foundation

let ghosttyXCFrameworkRelativePath = "Dependencies/GhosttyKit.xcframework"
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
let ghosttyXCFrameworkCandidatePaths = [
    "\(manifestRootPath)/\(ghosttyXCFrameworkRelativePath)",
    "\(workingDirectoryRootPath)/\(ghosttyXCFrameworkRelativePath)",
]
let hasGhosttyXCFrameworkArtifact = ghosttyXCFrameworkCandidatePaths.contains {
    FileManager.default.fileExists(atPath: $0)
}
let hasGhosttyXCFramework = hasGhosttyXCFrameworkArtifact && !ghosttyIntegrationDisabled

var appDependencies: [TargetDependency] = [
    .target(name: "CoreState"),
]

var appTargetSettings: Settings?

if hasGhosttyXCFramework {
    appDependencies.append(.xcframework(path: .relativeToRoot(ghosttyXCFrameworkRelativePath)))
    appTargetSettings = .settings(
        base: [
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) TOASTTY_HAS_GHOSTTY_KIT",
            // Ghostty's static archive includes C++ objects and macOS text-input symbols.
            "OTHER_LDFLAGS": .array([
                "$(inherited)",
                "-lc++",
                "-framework",
                "Carbon",
            ]),
        ]
    )
}

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
            bundleId: "dev.toastty.app",
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
            bundleId: "dev.toastty.core",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Sources/Core/**"]
        ),
        .target(
            name: "CoreStateTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.toastty.core.tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Tests/Core/**"],
            dependencies: [
                .target(name: "CoreState"),
            ]
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
            runAction: .runAction(
                executable: .project(path: .relativeToRoot("."), target: "ToasttyApp"),
                arguments: .arguments(
                    environmentVariables: [
                        "TOASTTY_LOG_LEVEL": .environmentVariable(value: "debug", isEnabled: true),
                    ]
                )
            )
        ),
    ],
)
