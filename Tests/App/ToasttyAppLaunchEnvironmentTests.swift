@testable import ToasttyApp
import CoreState
import Foundation
import XCTest

final class ToasttyAppLaunchEnvironmentTests: XCTestCase {
    func testBaseLaunchEnvironmentIncludesAppResourcesPathWhenAvailable() {
        let panelID = UUID()
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-home",
            environment: [:]
        )

        let environment = ToasttyApp.baseLaunchEnvironment(
            panelID: panelID,
            runtimePaths: runtimePaths,
            socketPath: "/tmp/toastty.sock",
            cliExecutablePath: "/Applications/Toastty.app/Contents/Helpers/toastty",
            appResourcesPath: "/Applications/Toastty.app/Contents/Resources",
            shimDirectoryPath: "/tmp/toastty/bin",
            basePath: "/usr/bin:/bin",
            agentBasePath: "/opt/agents/bin"
        )

        XCTAssertEqual(
            environment[ToasttyLaunchContextEnvironment.panelIDKey],
            panelID.uuidString
        )
        XCTAssertEqual(
            environment[ToasttyLaunchContextEnvironment.socketPathKey],
            "/tmp/toastty.sock"
        )
        XCTAssertEqual(
            environment[ToasttyLaunchContextEnvironment.paneJournalFileKey],
            "/tmp/toastty-home/.toastty/history/pane-journals/\(panelID.uuidString).journal"
        )
        XCTAssertEqual(
            environment[ToasttyLaunchContextEnvironment.cliPathKey],
            "/Applications/Toastty.app/Contents/Helpers/toastty"
        )
        XCTAssertEqual(
            environment[ToasttyLaunchContextEnvironment.appResourcesPathKey],
            "/Applications/Toastty.app/Contents/Resources"
        )
        XCTAssertEqual(
            environment[ToasttyLaunchContextEnvironment.agentBasePathKey],
            "/opt/agents/bin"
        )
        XCTAssertEqual(
            environment[ToasttyLaunchContextEnvironment.agentShimDirectoryKey],
            "/tmp/toastty/bin"
        )
        XCTAssertEqual(environment["PATH"], "/tmp/toastty/bin:/usr/bin:/bin")
    }

    func testBaseLaunchEnvironmentOmitsAppResourcesPathWhenUnavailable() {
        let panelID = UUID()
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-home",
            environment: [:]
        )

        let environment = ToasttyApp.baseLaunchEnvironment(
            panelID: panelID,
            runtimePaths: runtimePaths,
            socketPath: "/tmp/toastty.sock",
            cliExecutablePath: nil,
            appResourcesPath: nil,
            shimDirectoryPath: nil,
            basePath: "/usr/bin:/bin",
            agentBasePath: nil
        )

        XCTAssertNil(environment[ToasttyLaunchContextEnvironment.cliPathKey])
        XCTAssertNil(environment[ToasttyLaunchContextEnvironment.appResourcesPathKey])
        XCTAssertNil(environment[ToasttyLaunchContextEnvironment.agentBasePathKey])
        XCTAssertNil(environment[ToasttyLaunchContextEnvironment.agentShimDirectoryKey])
        XCTAssertNil(environment["PATH"])
    }
}
