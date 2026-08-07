@testable import ToasttyApp
import CoreState
import XCTest

final class GettingStartedEligibilityTests: XCTestCase {
    func testFreshPersistentRunAllowsAutomaticPresentation() throws {
        let fixture = try makeFixture()

        let footprint = GettingStartedEligibility.setupFootprint(
            runtimePaths: fixture.runtimePaths,
            userDefaults: fixture.userDefaults,
            homeDirectoryPath: fixture.homeURL.path,
            environment: fixture.environment
        )

        XCTAssertFalse(footprint.exists)
        XCTAssertTrue(
            GettingStartedEligibility.allowsAutoPresentation(
                usesPersistentPreferences: true,
                setupFootprint: footprint
            )
        )
    }

    func testAutomationRunDisablesAutomaticPresentation() throws {
        let fixture = try makeFixture()
        let footprint = GettingStartedEligibility.setupFootprint(
            runtimePaths: fixture.runtimePaths,
            userDefaults: fixture.userDefaults,
            homeDirectoryPath: fixture.homeURL.path,
            environment: fixture.environment
        )

        XCTAssertFalse(
            GettingStartedEligibility.allowsAutoPresentation(
                usesPersistentPreferences: false,
                setupFootprint: footprint
            )
        )
    }

    func testFreshPersistentRunDefersStartupSetupTemplates() throws {
        let fixture = try makeFixture()
        let footprint = GettingStartedEligibility.setupFootprint(
            runtimePaths: fixture.runtimePaths,
            userDefaults: fixture.userDefaults,
            homeDirectoryPath: fixture.homeURL.path,
            environment: fixture.environment
        )

        XCTAssertFalse(
            GettingStartedEligibility.shouldCreateStartupSetupTemplates(
                usesPersistentPreferences: true,
                setupFootprint: footprint
            )
        )
    }

    func testAppKitDefaultPreferenceWritesDoNotCreateSetupFootprint() throws {
        let fixture = try makeFixture()
        AppKitDefaultPreferences.apply(to: fixture.userDefaults, standardDefaults: fixture.userDefaults)

        let footprint = GettingStartedEligibility.setupFootprint(
            runtimePaths: fixture.runtimePaths,
            userDefaults: fixture.userDefaults,
            homeDirectoryPath: fixture.homeURL.path,
            environment: fixture.environment
        )

        XCTAssertFalse(footprint.hasPersistedSettings)
        XCTAssertFalse(footprint.exists)
    }

    func testAutomationRunStillCreatesStartupSetupTemplates() throws {
        let fixture = try makeFixture()
        let footprint = GettingStartedEligibility.setupFootprint(
            runtimePaths: fixture.runtimePaths,
            userDefaults: fixture.userDefaults,
            homeDirectoryPath: fixture.homeURL.path,
            environment: fixture.environment
        )

        XCTAssertTrue(
            GettingStartedEligibility.shouldCreateStartupSetupTemplates(
                usesPersistentPreferences: false,
                setupFootprint: footprint
            )
        )
    }

    func testSetupFootprintDetectsToasttyConfig() throws {
        let fixture = try makeFixture()
        try writeEmptyFile(at: fixture.runtimePaths.configFileURL)

        let footprint = GettingStartedEligibility.setupFootprint(
            runtimePaths: fixture.runtimePaths,
            userDefaults: fixture.userDefaults,
            homeDirectoryPath: fixture.homeURL.path,
            environment: fixture.environment
        )

        XCTAssertTrue(footprint.hasToasttyConfig)
        XCTAssertTrue(footprint.exists)
        XCTAssertFalse(
            GettingStartedEligibility.allowsAutoPresentation(
                usesPersistentPreferences: true,
                setupFootprint: footprint
            )
        )
        XCTAssertTrue(
            GettingStartedEligibility.shouldCreateStartupSetupTemplates(
                usesPersistentPreferences: true,
                setupFootprint: footprint
            )
        )
    }

    func testSetupFootprintDetectsWorkspaceLayouts() throws {
        let fixture = try makeFixture()
        try writeEmptyFile(at: fixture.runtimePaths.workspaceLayoutsFileURL)

        let footprint = GettingStartedEligibility.setupFootprint(
            runtimePaths: fixture.runtimePaths,
            userDefaults: fixture.userDefaults,
            homeDirectoryPath: fixture.homeURL.path,
            environment: fixture.environment
        )

        XCTAssertTrue(footprint.hasWorkspaceLayouts)
        XCTAssertTrue(footprint.exists)
    }

    func testSetupFootprintDetectsAgentProfiles() throws {
        let fixture = try makeFixture()
        try writeEmptyFile(at: AgentProfilesFile.fileURL(homeDirectoryPath: fixture.homeURL.path))

        let footprint = GettingStartedEligibility.setupFootprint(
            runtimePaths: fixture.runtimePaths,
            userDefaults: fixture.userDefaults,
            homeDirectoryPath: fixture.homeURL.path,
            environment: fixture.environment
        )

        XCTAssertTrue(footprint.hasAgentProfiles)
        XCTAssertTrue(footprint.exists)
    }

    func testSetupFootprintDetectsTerminalProfiles() throws {
        let fixture = try makeFixture()
        try writeEmptyFile(
            at: TerminalProfilesFile.fileURL(
                homeDirectoryPath: fixture.homeURL.path,
                environment: fixture.environment
            )
        )

        let footprint = GettingStartedEligibility.setupFootprint(
            runtimePaths: fixture.runtimePaths,
            userDefaults: fixture.userDefaults,
            homeDirectoryPath: fixture.homeURL.path,
            environment: fixture.environment
        )

        XCTAssertTrue(footprint.hasTerminalProfiles)
        XCTAssertTrue(footprint.exists)
    }

    func testSetupFootprintDetectsPersistedSettings() throws {
        let fixture = try makeFixture()
        ToasttySettingsStore.persistAskBeforeQuitting(false, userDefaults: fixture.userDefaults)

        let footprint = GettingStartedEligibility.setupFootprint(
            runtimePaths: fixture.runtimePaths,
            userDefaults: fixture.userDefaults,
            homeDirectoryPath: fixture.homeURL.path,
            environment: fixture.environment
        )

        XCTAssertTrue(footprint.hasPersistedSettings)
        XCTAssertTrue(footprint.exists)
    }

    private func makeFixture(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Fixture {
        let rootURL = URL(filePath: NSTemporaryDirectory())
            .appending(path: "toastty-getting-started-eligibility-\(UUID().uuidString)", directoryHint: .isDirectory)
        let homeURL = rootURL.appending(path: "home", directoryHint: .isDirectory)
        let runtimeHomeURL = rootURL.appending(path: "runtime-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let environment = [ToasttyRuntimePaths.environmentKey: runtimeHomeURL.path]
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeURL.path,
            environment: environment
        )
        let suiteName = "toastty-getting-started-eligibility-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
        userDefaults.removePersistentDomain(forName: suiteName)
        return Fixture(
            homeURL: homeURL,
            environment: environment,
            runtimePaths: runtimePaths,
            userDefaults: userDefaults
        )
    }

    private func writeEmptyFile(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
    }

    private struct Fixture {
        let homeURL: URL
        let environment: [String: String]
        let runtimePaths: ToasttyRuntimePaths
        let userDefaults: UserDefaults
    }
}
