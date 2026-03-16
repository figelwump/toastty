import Foundation
import XCTest
@testable import ToasttyApp

final class AgentLaunchInstrumentationTests: XCTestCase {
    func testPrepareClaudeLaunchMergesInlineSettingsArgument() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: [
                "claude",
                "--settings={\"model\":\"sonnet\",\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/bin/echo existing\"}]}]}}",
            ],
            cliExecutablePath: "/bin/sh",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(preparedLaunch.argv.first, "claude")
        let settingsIndex = try XCTUnwrap(preparedLaunch.argv.firstIndex(of: "--settings"))
        let settingsPath = try XCTUnwrap(preparedLaunch.argv[safe: settingsIndex + 1])
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "sonnet")
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["UserPromptSubmit"])
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertNotNil(hooks["PostToolUse"])
        XCTAssertNotNil(hooks["PostToolUseFailure"])
        XCTAssertNotNil(hooks["PermissionRequest"])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
