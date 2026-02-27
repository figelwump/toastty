import CoreState
import Foundation
import Testing

struct AutomationTests {
    @Test
    func parseAutomationConfigFromArgumentsAndEnvironment() throws {
        let config = try #require(
            AutomationConfig.parse(
                arguments: [
                    "toastty",
                    "--automation",
                    "--run-id", "chunk-b",
                    "--fixture", "two-workspaces",
                    "--artifacts-dir", "/tmp/toastty-artifacts",
                ],
                environment: [
                    "TOASTTY_DISABLE_ANIMATIONS": "1",
                    "TOASTTY_FIXED_LOCALE": "en_US_POSIX",
                    "TOASTTY_FIXED_TIMEZONE": "UTC",
                ]
            )
        )

        #expect(config.runID == "chunk-b")
        #expect(config.fixtureName == "two-workspaces")
        #expect(config.artifactsDirectory == "/tmp/toastty-artifacts")
        #expect(config.disableAnimations == true)
        #expect(config.fixedLocaleIdentifier == "en_US_POSIX")
        #expect(config.fixedTimeZoneIdentifier == "UTC")
    }

    @Test
    func parseAutomationConfigReturnsNilWhenDisabled() {
        #expect(
            AutomationConfig.parse(arguments: ["toastty"], environment: [:]) == nil
        )
    }

    @Test
    func parseAutomationConfigSupportsFixtureFromEnvironmentAndDisableAnimationsArgument() throws {
        let config = try #require(
            AutomationConfig.parse(
                arguments: [
                    "toastty",
                    "--automation",
                    "--disable-animations",
                ],
                environment: [
                    "TOASTTY_FIXTURE": "split-workspace",
                ]
            )
        )

        #expect(config.fixtureName == "split-workspace")
        #expect(config.disableAnimations == true)
        #expect(config.artifactsDirectory != nil)
    }

    @Test
    func twoWorkspaceFixtureLoadsExpectedShape() throws {
        let fixture = try #require(AutomationFixtureLoader.load(named: "two-workspaces"))

        #expect(fixture.windows.count == 1)
        let window = try #require(fixture.windows.first)
        #expect(window.workspaceIDs.count == 2)
        #expect(window.selectedWorkspaceID == window.workspaceIDs.first)

        for workspaceID in window.workspaceIDs {
            #expect(fixture.workspacesByID[workspaceID] != nil)
        }

        try StateValidator.validate(fixture)
    }

    @Test
    func loadRequiredFixtureThrowsForUnknownFixture() {
        #expect(throws: AutomationFixtureError.unknownFixture("not-real")) {
            _ = try AutomationFixtureLoader.loadRequired(named: "not-real")
        }
    }
}
