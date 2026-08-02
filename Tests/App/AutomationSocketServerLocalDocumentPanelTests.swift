@testable import ToasttyApp
import CoreState
import CryptoKit
import Darwin
import Foundation
import XCTest

final class AutomationSocketServerLocalDocumentPanelTests: AutomationSocketServerWindowTargetingTestCase {
    func testMarkdownPanelAutomationCreatesSelectedTabAndExposesBootstrapState() async throws {
        let fixture = makeSingleWindowFixture()
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-markdown-automation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let markdownURL = tempDirectory.appendingPathComponent("smoke.md", isDirectory: false)
        let markdownContent = """
        ---
        author: Automation
        tags: smoke, markdown
        ---
        # Markdown Smoke

        - alpha
        - beta
        """
        try markdownContent.write(to: markdownURL, atomically: true, encoding: .utf8)
        let expectedHash = SHA256.hash(data: Data(markdownContent.utf8)).map { String(format: "%02x", $0) }.joined()

        try await withAutomationHarness(state: fixture.state) { harness in
            let createResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "panel.create.localDocument",
                    "args": [
                        "placement": "newTab",
                        "filePath": markdownURL.path,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(createResponse.ok)

            let workspace = try await MainActor.run {
                try XCTUnwrap(harness.store.state.workspacesByID[fixture.workspaceID])
            }
            XCTAssertEqual(workspace.tabIDs.count, 2)
            let panelID = try XCTUnwrap(workspace.focusedPanelID)
            guard case .web(let webState) = workspace.panels[panelID] else {
                XCTFail("expected focused panel to be markdown")
                return
            }
            XCTAssertEqual(webState.definition, .localDocument)
            XCTAssertEqual(webState.filePath, markdownURL.path)

            var snapshotResponse: AutomationSocketTestResponse?
            for _ in 0 ..< 40 {
                let response = try sendRequest(
                    command: "automation.local_document_panel_state",
                    payload: [
                        "panelID": panelID.uuidString,
                    ],
                    socketPath: harness.socketPath
                )
                XCTAssertTrue(response.ok)
                snapshotResponse = response
                if response.result["bootstrapContentSHA256"] as? String == expectedHash {
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            let finalSnapshot = try XCTUnwrap(snapshotResponse)
            XCTAssertEqual(finalSnapshot.result["workspaceID"] as? String, fixture.workspaceID.uuidString)
            XCTAssertEqual(finalSnapshot.result["panelID"] as? String, panelID.uuidString)
            XCTAssertEqual(finalSnapshot.result["stateFilePath"] as? String, markdownURL.path)
            XCTAssertEqual(finalSnapshot.result["stateFormat"] as? String, "markdown")
            XCTAssertEqual(finalSnapshot.result["bootstrapFilePath"] as? String, markdownURL.path)
            XCTAssertEqual(finalSnapshot.result["bootstrapDisplayName"] as? String, "smoke.md")
            XCTAssertEqual(finalSnapshot.result["bootstrapFormat"] as? String, "markdown")
            XCTAssertEqual(finalSnapshot.result["bootstrapShouldHighlight"] as? Bool, true)
            XCTAssertEqual(finalSnapshot.result["bootstrapContentSHA256"] as? String, expectedHash)
            XCTAssertEqual(finalSnapshot.result["bootstrapContentRevision"] as? Int, 1)
            XCTAssertEqual(finalSnapshot.result["bootstrapIsEditing"] as? Bool, false)
            XCTAssertEqual(finalSnapshot.result["bootstrapIsDirty"] as? Bool, false)
            XCTAssertEqual(finalSnapshot.result["currentTheme"] as? String, "dark")
            XCTAssertEqual(finalSnapshot.result["bootstrapTextScale"] as? Double, 1.0)
            XCTAssertEqual(finalSnapshot.result["hostLifecycleState"] as? String, "detached")
        }
    }

    func testMarkdownAutomationAliasesStillCreateAndInspectLocalDocumentPanel() async throws {
        let fixture = makeSingleWindowFixture()
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-markdown-automation-alias-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let markdownURL = tempDirectory.appendingPathComponent("alias.md", isDirectory: false)
        let markdownContent = "# Alias Smoke\n"
        try markdownContent.write(to: markdownURL, atomically: true, encoding: .utf8)
        let expectedHash = SHA256.hash(data: Data(markdownContent.utf8)).map { String(format: "%02x", $0) }.joined()

        try await withAutomationHarness(state: fixture.state) { harness in
            let createResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "panel.create.markdown",
                    "args": [
                        "placement": "newTab",
                        "filePath": markdownURL.path,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(createResponse.ok)

            let workspace = try await MainActor.run {
                try XCTUnwrap(harness.store.state.workspacesByID[fixture.workspaceID])
            }
            let panelID = try XCTUnwrap(workspace.focusedPanelID)
            var snapshotResponse: AutomationSocketTestResponse?
            for _ in 0 ..< 40 {
                let response = try sendRequest(
                    command: "automation.markdown_panel_state",
                    payload: [
                        "panelID": panelID.uuidString,
                    ],
                    socketPath: harness.socketPath
                )
                XCTAssertTrue(response.ok)
                snapshotResponse = response
                if response.result["bootstrapContentSHA256"] as? String == expectedHash {
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            let finalSnapshot = try XCTUnwrap(snapshotResponse)
            XCTAssertEqual(finalSnapshot.result["bootstrapDisplayName"] as? String, "alias.md")
            XCTAssertEqual(finalSnapshot.result["bootstrapFormat"] as? String, "markdown")
        }
    }

    func testJsonPanelAutomationCreatesSelectedTabAndExposesBootstrapState() async throws {
        let fixture = makeSingleWindowFixture()
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-json-automation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let jsonURL = tempDirectory.appendingPathComponent("package.json", isDirectory: false)
        let jsonContent = """
        {
          "name": "toastty",
          "private": true,
          "version": "0.1.0"
        }
        """
        try jsonContent.write(to: jsonURL, atomically: true, encoding: .utf8)
        let expectedHash = SHA256.hash(data: Data(jsonContent.utf8)).map { String(format: "%02x", $0) }.joined()

        try await withAutomationHarness(state: fixture.state) { harness in
            let createResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "panel.create.localDocument",
                    "args": [
                        "placement": "newTab",
                        "filePath": jsonURL.path,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(createResponse.ok)

            let workspace = try await MainActor.run {
                try XCTUnwrap(harness.store.state.workspacesByID[fixture.workspaceID])
            }
            let panelID = try XCTUnwrap(workspace.focusedPanelID)

            var snapshotResponse: AutomationSocketTestResponse?
            for _ in 0 ..< 40 {
                let response = try sendRequest(
                    command: "automation.local_document_panel_state",
                    payload: [
                        "panelID": panelID.uuidString,
                    ],
                    socketPath: harness.socketPath
                )
                XCTAssertTrue(response.ok)
                snapshotResponse = response
                if response.result["bootstrapContentSHA256"] as? String == expectedHash {
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            let finalSnapshot = try XCTUnwrap(snapshotResponse)
            XCTAssertEqual(finalSnapshot.result["stateFilePath"] as? String, jsonURL.path)
            XCTAssertEqual(finalSnapshot.result["stateFormat"] as? String, "json")
            XCTAssertEqual(finalSnapshot.result["bootstrapDisplayName"] as? String, "package.json")
            XCTAssertEqual(finalSnapshot.result["bootstrapFormat"] as? String, "json")
            XCTAssertEqual(finalSnapshot.result["bootstrapShouldHighlight"] as? Bool, true)
            XCTAssertEqual(finalSnapshot.result["bootstrapContentSHA256"] as? String, expectedHash)
        }
    }

    func testLocalDocumentSearchActionsExposeSearchState() async throws {
        let fixture = makeSingleWindowFixture()
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-local-document-search-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let markdownURL = tempDirectory.appendingPathComponent("search.md", isDirectory: false)
        let markdownContent = """
        # Search Smoke

        Toastty finds toastty in this document.
        """
        try markdownContent.write(to: markdownURL, atomically: true, encoding: .utf8)
        let expectedHash = SHA256.hash(data: Data(markdownContent.utf8)).map { String(format: "%02x", $0) }.joined()

        try await withAutomationHarness(state: fixture.state) { harness in
            let createResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "panel.create.local-document",
                    "args": [
                        "placement": "newTab",
                        "filePath": markdownURL.path,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(createResponse.ok)

            let workspace = try await MainActor.run {
                try XCTUnwrap(harness.store.state.workspacesByID[fixture.workspaceID])
            }
            let panelID = try XCTUnwrap(workspace.focusedPanelID)

            var snapshotResponse: AutomationSocketTestResponse?
            for _ in 0 ..< 40 {
                let response = try sendRequest(
                    command: "automation.local_document_panel_state",
                    payload: [
                        "panelID": panelID.uuidString,
                    ],
                    socketPath: harness.socketPath
                )
                XCTAssertTrue(response.ok)
                snapshotResponse = response
                if response.result["bootstrapContentSHA256"] as? String == expectedHash {
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            XCTAssertEqual(snapshotResponse?.result["searchIsPresented"] as? Bool, false)
            XCTAssertTrue(snapshotResponse?.result["searchQuery"] is NSNull)
            XCTAssertTrue(snapshotResponse?.result["searchLastMatchFound"] is NSNull)
            XCTAssertEqual(snapshotResponse?.result["searchFieldFocused"] as? Bool, false)

            let startResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "panel.local-document.search.start",
                    "args": [
                        "panelID": panelID.uuidString,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(startResponse.ok)

            var startedSnapshot: AutomationSocketTestResponse?
            for _ in 0 ..< 20 {
                let response = try sendRequest(
                    command: "automation.local_document_panel_state",
                    payload: [
                        "panelID": panelID.uuidString,
                    ],
                    socketPath: harness.socketPath
                )
                XCTAssertTrue(response.ok)
                startedSnapshot = response
                if response.result["searchIsPresented"] as? Bool == true {
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            XCTAssertEqual(startedSnapshot?.result["searchIsPresented"] as? Bool, true)
            XCTAssertEqual(startedSnapshot?.result["searchQuery"] as? String, "")
            XCTAssertEqual(startedSnapshot?.result["searchFieldFocused"] as? Bool, false)

            let updateResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "panel.local-document.search.update-query",
                    "args": [
                        "panelID": panelID.uuidString,
                        "query": "toastty",
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(updateResponse.ok)

            var searchedSnapshot: AutomationSocketTestResponse?
            for _ in 0 ..< 40 {
                let response = try sendRequest(
                    command: "automation.local_document_panel_state",
                    payload: [
                        "panelID": panelID.uuidString,
                    ],
                    socketPath: harness.socketPath
                )
                XCTAssertTrue(response.ok)
                searchedSnapshot = response
                if response.result["searchQuery"] as? String == "toastty",
                   response.result["searchLastMatchFound"] as? Bool != nil {
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            XCTAssertEqual(searchedSnapshot?.result["searchIsPresented"] as? Bool, true)
            XCTAssertEqual(searchedSnapshot?.result["searchQuery"] as? String, "toastty")
            XCTAssertNotNil(searchedSnapshot?.result["searchLastMatchFound"] as? Bool)

            let nextResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "panel.local-document.search.next",
                    "args": [
                        "panelID": panelID.uuidString,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(nextResponse.ok)

            let previousResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "panel.local-document.search.previous",
                    "args": [
                        "panelID": panelID.uuidString,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(previousResponse.ok)

            let hideResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "panel.local-document.search.hide",
                    "args": [
                        "panelID": panelID.uuidString,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(hideResponse.ok)

            let hiddenSnapshot = try sendRequest(
                command: "automation.local_document_panel_state",
                payload: [
                    "panelID": panelID.uuidString,
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(hiddenSnapshot.ok)
            XCTAssertEqual(hiddenSnapshot.result["searchIsPresented"] as? Bool, false)
            XCTAssertTrue(hiddenSnapshot.result["searchQuery"] is NSNull)
            XCTAssertTrue(hiddenSnapshot.result["searchLastMatchFound"] is NSNull)
        }
    }

}
