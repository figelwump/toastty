@testable import ToasttyApp
import CoreState
import Foundation
import XCTest

final class GettingStartedPageDriftTests: XCTestCase {
    func testPageContainsCanonicalOnboardingAndManualSetupContent() throws {
        let pageSource = try pageSource()

        XCTAssertTrue(pageSource.contains(htmlEscaped(GettingStartedContent.onboardingPrompt)))
        for command in [
            GettingStartedContent.shellIntegrationCommand,
            GettingStartedContent.codexStatusHooksCommand,
            GettingStartedContent.skillsListCommand,
        ] {
            XCTAssertTrue(pageSource.contains(htmlEscaped(command)), "Page is missing \(command)")
        }

        for agentName in GettingStartedContent.supportedAgentNames {
            XCTAssertTrue(pageSource.contains(agentName), "Page is missing \(agentName)")
        }

        XCTAssertTrue(pageSource.contains(GettingStartedContent.shellIntegrationManualRowBody))
        XCTAssertTrue(pageSource.contains(GettingStartedContent.shellIntegrationRestartNotice))
        XCTAssertTrue(pageSource.contains("toastty://action/open-skills-management"))
        // Each action link names an action the app performs.
        for action in ["open-skills-management", "open-agent-profiles", "open-shortcut-reference", "open-coordinator"] {
            XCTAssertNotNil(GettingStartedPanelNativeAction(rawValue: action), action)
        }
        XCTAssertTrue(pageSource.contains("toastty://action/open-coordinator"))
        // The first task, with the keys the app uses.
        XCTAssertTrue(pageSource.contains("git repository"))
        // The page names the macOS keys; Linux labels them as GTK does
        // (`QuickEntryShortcut.symbolLabel`).
        #if !os(Linux)
        XCTAssertTrue(pageSource.contains("<kbd>\(QuickEntryShortcut.default.symbolLabel)</kbd>"))
        #endif
        XCTAssertTrue(pageSource.contains("<kbd>\(ToasttyKeyboardShortcuts.toggleTasksView.symbolLabel)</kbd>"))
        XCTAssertTrue(pageSource.contains("~/.toastty/skills"))
        XCTAssertFalse(pageSource.contains("setup print-skill"))
        XCTAssertFalse(pageSource.contains("setup install-skill"))
    }

    func testPageHasRequiredAnchorsAndSelfContainedContentPolicy() throws {
        let pageSource = try pageSource()

        for anchorID in ["onboarding", "tasks", "manual-setup", "codex-hooks", "shortcuts"] {
            XCTAssertTrue(pageSource.contains("id=\"\(anchorID)\""), "Page is missing #\(anchorID)")
        }

        XCTAssertTrue(
            pageSource.contains(
                #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:">"#
            )
        )
        XCTAssertFalse(pageSource.contains("http://"))
        XCTAssertFalse(pageSource.contains("https://"))
    }

    private func pageSource() throws -> String {
        try String(
            contentsOf: repoRootURL()
                .appendingPathComponent(
                    "Sources/App/Resources/WebPanels/getting-started-panel/index.html",
                    isDirectory: false
                ),
            encoding: .utf8
        )
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func htmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
