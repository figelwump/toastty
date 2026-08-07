import CoreState
import Foundation
import Testing
@testable import ToasttyCLIKit

struct SetupResourceResolverTests {
    @Test
    func resourcesDirectoryPrefersLaunchEnvironmentPath() {
        let url = SetupResourceResolver.resourcesDirectoryURL(
            environment: [
                ToasttyLaunchContextEnvironment.appResourcesPathKey: "/Applications/Toastty.app/Contents/Resources",
            ],
            executableURL: URL(fileURLWithPath: "/Applications/Toastty.app/Contents/Helpers/toastty")
        )

        #expect(url.path == "/Applications/Toastty.app/Contents/Resources")
    }

    @Test
    func resourcesDirectoryPreservesExplicitLaunchEnvironmentPath() {
        let resourcesPath = "/tmp/Toastty Resources "
        let url = SetupResourceResolver.resourcesDirectoryURL(
            environment: [
                ToasttyLaunchContextEnvironment.appResourcesPathKey: resourcesPath,
            ],
            executableURL: URL(fileURLWithPath: "/Applications/Toastty.app/Contents/Helpers/toastty")
        )

        #expect(url.path == resourcesPath)
    }

    @Test
    func resourcesDirectoryIgnoresBlankLaunchEnvironmentPath() {
        let url = SetupResourceResolver.resourcesDirectoryURL(
            environment: [
                ToasttyLaunchContextEnvironment.appResourcesPathKey: " \n\t ",
            ],
            executableURL: URL(fileURLWithPath: "/Applications/Toastty.app/Contents/Helpers/toastty")
        )

        #expect(url.path == "/Applications/Toastty.app/Contents/Resources")
    }

    @Test
    func resourcesDirectoryFallsBackToHelperLayout() {
        let url = SetupResourceResolver.resourcesDirectoryURL(
            environment: [:],
            executableURL: URL(fileURLWithPath: "/Applications/Toastty.app/Contents/Helpers/toastty")
        )

        #expect(url.path == "/Applications/Toastty.app/Contents/Resources")
    }

    @Test
    func resourcesDirectorySupportsStagedShimCopyViaLaunchEnvironment() {
        let url = SetupResourceResolver.resourcesDirectoryURL(
            environment: [
                ToasttyLaunchContextEnvironment.appResourcesPathKey: "/private/tmp/toastty-runtime/Toastty.app/Contents/Resources",
            ],
            executableURL: URL(fileURLWithPath: "/private/tmp/toastty-runtime/agent-shims/toastty")
        )

        #expect(url.path == "/private/tmp/toastty-runtime/Toastty.app/Contents/Resources")
    }

    @Test
    func resourcesDirectoryCanResolveFromCurrentExecutableByDefault() {
        let url = SetupResourceResolver.resourcesDirectoryURL(environment: [:])

        #expect(url.lastPathComponent == "Resources")
    }

    @Test
    func setupDirectoryAppendsSetupToResolvedResources() {
        let url = SetupResourceResolver.setupDirectoryURL(
            environment: [
                ToasttyLaunchContextEnvironment.appResourcesPathKey: "/Applications/Toastty.app/Contents/Resources",
            ],
            executableURL: URL(fileURLWithPath: "/unused/toastty")
        )

        #expect(url.path == "/Applications/Toastty.app/Contents/Resources/Setup")
    }
}
