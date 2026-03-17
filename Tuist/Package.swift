// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "toastty-dependencies",
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.8.1"),
    ]
)
