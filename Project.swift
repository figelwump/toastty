import ProjectDescription

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
            dependencies: [
                .target(name: "CoreState"),
            ]
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
    ]
)
