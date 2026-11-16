import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class WorkspacePreviewMetadataTests: XCTestCase {
    func testOlderHostWithoutWorkspaceMetadataStillDecodes() throws {
        let result = try GatewayCompatibilityDecoder().decodeSessionListResponse(snapshotData(workspaces: nil))
        XCTAssertTrue(result.workspaces.isEmpty)
    }

    func testPanelOnlyWorkspaceAndUnknownPanelKindSurviveSnapshotPresentation() throws {
        let id = UUID()
        let panelID = UUID()
        let workspace: [String: Any] = ["id": id.uuidString, "title": "Documents", "panels": [
            ["panelID": panelID.uuidString, "auxiliaryTabID": UUID().uuidString,
             "workspaceTabID": UUID().uuidString, "workspaceTabTitle": "Research", "kind": "future_kind", "title": "Future panel"],
            ["malformed": true]
        ]]
        let result = try GatewayCompatibilityDecoder().decodeSessionListResponse(snapshotData(workspaces: [workspace]))
        let presentation = result.presentation()
        XCTAssertTrue(presentation.activitySessions.isEmpty)
        XCTAssertEqual(presentation.rankedWorkspaces.first?.id, id)
        XCTAssertEqual(presentation.rankedWorkspaces.first?.panels.map(\.panelID), [panelID])
        XCTAssertEqual(presentation.rankedWorkspaces.first?.panels.first?.kind, "future_kind")
        XCTAssertNil(presentation.rankedWorkspaces.first?.panels.first?.updatedAt)
        XCTAssertNil(presentation.rankedWorkspaces.first?.panels.first?.associatedConversationID)
    }

    func testPanelUpdateTimestampSurvivesCompatibilityDecoding() throws {
        let workspace: [String: Any] = ["id": UUID().uuidString, "title": "Documents", "panels": [
            ["panelID": UUID().uuidString, "auxiliaryTabID": UUID().uuidString,
             "workspaceTabID": UUID().uuidString, "workspaceTabTitle": "Research", "kind": "localDocument",
             "title": "Notes", "updatedAt": "2026-09-06T12:00:00.000Z"]
        ]]
        let result = try GatewayCompatibilityDecoder().decodeSessionListResponse(snapshotData(workspaces: [workspace]))
        XCTAssertEqual(result.presentation().rankedWorkspaces.first?.panels.first?.updatedAt,
                       ISO8601DateFormatter().date(from: "2026-09-06T12:00:00Z"))
    }

    func testHostEncodedPanelTimestampRoundTripsThroughCompatibilityDecoder() throws {
        let timestamp = Date(timeIntervalSince1970: 1_788_696_000.125)
        let panel = RemoteWorkspacePanel(
            panelID: UUID(), auxiliaryTabID: UUID(), workspaceTabID: UUID(),
            workspaceTabTitle: "Research", kind: "scratchpad", title: "Notes", updatedAt: timestamp,
            associatedConversationID: RemoteConversationID(rawValue: UUID())
        )
        let response = RemoteGatewaySessionListResponse(snapshot: RemoteSessionListSnapshot(
            projectionRunID: RemoteProjectionRunID(rawValue: UUID()), conversations: [], generatedAt: timestamp,
            workspaces: [RemoteWorkspaceSummary(id: UUID(), title: "Documents", panels: [panel])]
        ))
        // This is the encoder used by RemoteGatewayRequestHandler for session lists.
        let data = try ConversationEventCoding.makeEncoder().encode(response)
        let decoded = try GatewayCompatibilityDecoder().decodeSessionListResponse(data)
        let decodedPanel = try XCTUnwrap(decoded.presentation().rankedWorkspaces.first?.panels.first)
        XCTAssertEqual(decodedPanel.updatedAt, timestamp)
        XCTAssertEqual(decodedPanel.panelID, panel.panelID)
        XCTAssertEqual(decodedPanel.associatedConversationID, panel.associatedConversationID)
    }

    func testHostEncodedFlagAndTurnTimingReachThePresentation() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_788_696_000)
        func summary(_ status: RemoteSessionPresentationStatus, turnStartedAt: Date?) -> RemoteConversationSummary {
            RemoteConversationSummary(
                conversationID: RemoteConversationID(), provider: .claude, title: "Session",
                placement: RemoteConversationPlacement(workspaceID: UUID(), workspaceTitle: "toastty"),
                state: .working, presentationStatus: status,
                inputAvailability: .unavailable(reason: .unknownProviderState),
                isFlaggedForLater: true, turnStartedAt: turnStartedAt, lastTurnDuration: 125,
                latestSequence: 0, updatedAt: generatedAt
            )
        }
        let response = RemoteGatewaySessionListResponse(snapshot: RemoteSessionListSnapshot(
            projectionRunID: RemoteProjectionRunID(rawValue: UUID()),
            conversations: [
                summary(.working, turnStartedAt: generatedAt.addingTimeInterval(-221)),
                // A turn start the Mac has moved past is dropped.
                summary(.ready, turnStartedAt: generatedAt.addingTimeInterval(-221)),
            ],
            generatedAt: generatedAt
        ))
        let data = try ConversationEventCoding.makeEncoder().encode(response)
        let presentation = try GatewayCompatibilityDecoder().decodeSessionListResponse(data)
            .presentation(receivedAtMonotonicTime: 1_000)
        let working = try XCTUnwrap(presentation.activitySessions.first { $0.state.bucket == .working })
        let ready = try XCTUnwrap(presentation.activitySessions.first { $0.state.bucket == .ready })

        XCTAssertTrue(working.isFlaggedForLater)
        XCTAssertEqual(working.elapsedTurnLabel(atMonotonicTime: 1_000), "3m 41s")
        XCTAssertEqual(working.elapsedTurnLabel(atMonotonicTime: 1_019), "4m 00s")
        XCTAssertEqual(working.lastTurnLabel, "2m 05s")
        XCTAssertNil(ready.turnElapsed)
        XCTAssertNil(ready.elapsedTurnLabel(atMonotonicTime: 1_000))

        // Older hosts send none of it.
        let plain = try GatewayCompatibilityDecoder().decodeSessionListResponse(snapshotData(workspaces: nil))
        XCTAssertTrue(plain.conversations.allSatisfy { $0.isFlaggedForLater == false && $0.turnStartedAt == nil })
    }

    func testHostEncodedSubspaceFieldsReachThePresentationAndOlderHostsStayFlat() throws {
        let parentID = UUID()
        let subspaceID = UUID()
        let reviewID = UUID()
        let spawner = RemoteConversationID(rawValue: UUID())
        let response = RemoteGatewaySessionListResponse(snapshot: RemoteSessionListSnapshot(
            projectionRunID: RemoteProjectionRunID(rawValue: UUID()), conversations: [],
            generatedAt: Date(timeIntervalSince1970: 1_788_696_000),
            workspaces: [
                RemoteWorkspaceSummary(id: parentID, title: "toastty", panels: []),
                RemoteWorkspaceSummary(
                    id: subspaceID, title: "task", panels: [],
                    annotations: [RemoteWorkspaceAnnotation(key: "ticket", text: "TOAST-7", color: "#7AA2F7")],
                    parentWorkspaceID: parentID, spawningConversationID: spawner,
                    primaryAnnotationKey: "ticket", doneAt: Date(timeIntervalSince1970: 1_788_695_000)
                ),
                // A task with an open pull request, which finishes through Merge.
                RemoteWorkspaceSummary(
                    id: reviewID, title: "review", panels: [], parentWorkspaceID: parentID, acceptsDoneMark: false
                ),
            ]
        ))
        // This is the encoder used by RemoteGatewayRequestHandler for session lists.
        let data = try ConversationEventCoding.makeEncoder().encode(response)
        let presentation = try GatewayCompatibilityDecoder().decodeSessionListResponse(data).presentation()

        XCTAssertEqual(presentation.topLevelWorkspaces.map(\.id), [parentID])
        // Workspaces keep the Mac sidebar's order, not their titles' order.
        XCTAssertEqual(presentation.workspaces.map(\.id), [parentID, subspaceID, reviewID])
        let row = try XCTUnwrap(presentation.subspaceRows(of: parentID).first { $0.id == subspaceID })
        XCTAssertEqual(row.id, subspaceID)
        XCTAssertEqual(row.status, .done)
        XCTAssertEqual(row.chip?.text, "TOAST-7")
        XCTAssertEqual(row.workspace.spawningConversationID, spawner.rawValue)
        XCTAssertEqual(presentation.parent(of: subspaceID)?.id, parentID)
        XCTAssertTrue(row.showsDoneToggle)
        let review = try XCTUnwrap(presentation.subspaceRows(of: parentID).first { $0.id == reviewID })
        XCTAssertFalse(review.workspace.acceptsDoneMark)
        XCTAssertFalse(review.showsDoneToggle)
        // The host sends the field only when the box is hidden.
        let plain = try ConversationEventCoding.makeEncoder().encode(
            RemoteWorkspaceSummary(id: subspaceID, title: "task", panels: [], parentWorkspaceID: parentID))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("acceptsDoneMark"))

        // An older host sends none of the fields, so every workspace is top level.
        let flat = try GatewayCompatibilityDecoder().decodeSessionListResponse(snapshotData(workspaces: [
            ["id": parentID.uuidString, "title": "toastty", "panels": []],
            ["id": subspaceID.uuidString, "title": "task", "panels": []],
        ])).presentation()
        XCTAssertEqual(Set(flat.topLevelWorkspaces.map(\.id)), [parentID, subspaceID])
        XCTAssertTrue(flat.subspaceRows(of: parentID).isEmpty)
        // Nor the done-mark field, so its subspaces keep the box.
        let older = try GatewayCompatibilityDecoder().decodeSessionListResponse(snapshotData(workspaces: [
            ["id": parentID.uuidString, "title": "toastty", "panels": []],
            ["id": subspaceID.uuidString, "title": "task", "panels": [], "parentWorkspaceID": parentID.uuidString],
        ])).presentation()
        XCTAssertEqual(older.subspaceRows(of: parentID).map(\.showsDoneToggle), [true])
    }

    func testCanonicalHostAnnotationsReachWorkspacesAndOlderWorkspacesHaveNone() throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v1", withExtension: nil))
        let rest = try GatewayCompatibilityDecoder().decodeSessionListResponse(Data(
            contentsOf: directory.appending(path: "session-list-response.json", directoryHint: .notDirectory)))
        guard case .sessionList(let streamed) = try GatewayCompatibilityDecoder().decodeStreamMessage(Data(
            contentsOf: directory.appending(path: "stream-session-list.json", directoryHint: .notDirectory)))
        else { return XCTFail("Expected a session_list stream message") }

        for snapshot in [rest, streamed] {
            let workspaces = snapshot.presentation().workspaces
            let annotated = try XCTUnwrap(workspaces.first { $0.title == "Mobile Remote Access" })
            XCTAssertEqual(annotated.annotations, [
                RemoteWorkspaceAnnotation(key: "github-pr", text: "PR #12",
                                          url: URL(string: "https://github.com/example/toastty/pull/12"),
                                          color: "#5BA08A"),
                RemoteWorkspaceAnnotation(key: "task-status", text: "Working", color: "#A78BFA"),
            ])
            XCTAssertEqual(workspaces.first { $0.title == "No annotations" }?.annotations, [])
        }
    }

    func testMalformedAnnotationsAreDroppedWithoutLosingTheWorkspace() throws {
        let valid: [String: Any] = ["id": UUID().uuidString, "title": "Chips", "panels": [], "annotations": [
            ["key": "ok", "text": "Kept", "color": "#5ba08a", "url": "https://example.com/a"],
            ["key": "bad-color", "text": "Neutral", "color": "green"],
            ["key": "bad-url", "text": "Text only", "color": "#E55C5C", "url": 42],
            ["key": "no-text", "color": "#E55C5C"],
            ["text": "No key", "color": "#E55C5C"],
        ]]
        let invalidField: [String: Any] = ["id": UUID().uuidString, "title": "Broken", "panels": [],
                                           "annotations": "not an array"]
        let result = try GatewayCompatibilityDecoder().decodeSessionListResponse(
            snapshotData(workspaces: [valid, invalidField]))
        let workspaces = result.presentation().workspaces

        let chips = try XCTUnwrap(workspaces.first { $0.title == "Chips" }?.annotations)
        XCTAssertEqual(chips.map(\.key), ["ok", "bad-color", "bad-url"])
        XCTAssertEqual(chips.map(\.color), ["#5BA08A", "#B7AEA5", "#E55C5C"])
        XCTAssertEqual(chips.map(\.url), [URL(string: "https://example.com/a"), nil, nil])
        XCTAssertEqual(workspaces.first { $0.title == "Broken" }?.annotations, [])
    }

    /// The Mac marks its coordinator's workspace. With a task board the
    /// phone sets it apart for the Coordinator tab; without one, or from an
    /// older Mac that sends no mark, it is an ordinary workspace.
    func testCoordinatorMarkSetsTheWorkspaceApartOnlyWithATaskBoard() throws {
        let projectID = UUID()
        let coordinatorID = UUID()
        let coordinatorConversation = RemoteConversationID(rawValue: UUID())
        func response(tasks: RemoteTaskBoard?) throws -> Data {
            try ConversationEventCoding.makeEncoder().encode(RemoteGatewaySessionListResponse(snapshot: RemoteSessionListSnapshot(
                projectionRunID: RemoteProjectionRunID(rawValue: UUID()), conversations: [],
                generatedAt: Date(timeIntervalSince1970: 1_788_696_000),
                workspaces: [
                    RemoteWorkspaceSummary(id: projectID, title: "toastty", panels: []),
                    RemoteWorkspaceSummary(
                        id: coordinatorID, title: "Coordinator", panels: [], isCoordinator: true,
                        coordinatorConversationID: coordinatorConversation
                    ),
                ],
                tasks: tasks
            )))
        }

        let withBoard = try GatewayCompatibilityDecoder().decodeSessionListResponse(response(tasks: RemoteTaskBoard()))
            .presentation()
        XCTAssertEqual(withBoard.coordinator?.id, coordinatorID)
        XCTAssertEqual(withBoard.topLevelWorkspaces.map(\.id), [projectID])
        XCTAssertEqual(withBoard.rankedWorkspaces.map(\.id), [projectID])
        // A lookup by ID still finds it, so its session can open.
        XCTAssertEqual(withBoard.workspaces.map(\.id), [projectID, coordinatorID])
        XCTAssertEqual(withBoard.workspaces.map(\.isCoordinator), [false, true])
        XCTAssertEqual(withBoard.coordinator?.coordinatorConversationID, coordinatorConversation.rawValue)
        // The named session is not in this snapshot's list, so none runs.
        XCTAssertEqual(withBoard.coordinatorMark, .notRunning)

        // Without a task board the phone has no tabs, so the workspace lists
        // as a project.
        let withoutBoard = try GatewayCompatibilityDecoder().decodeSessionListResponse(response(tasks: nil)).presentation()
        XCTAssertNil(withoutBoard.coordinator)
        XCTAssertNil(withoutBoard.coordinatorMark)
        XCTAssertEqual(Set(withoutBoard.topLevelWorkspaces.map(\.id)), [projectID, coordinatorID])

        // The Mac sends the field only for the coordinator's workspace.
        let plain = try ConversationEventCoding.makeEncoder().encode(
            RemoteWorkspaceSummary(id: projectID, title: "toastty", panels: []))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("isCoordinator"))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("coordinatorConversationID"))

        // An older Mac sends no mark, and a malformed one counts as none.
        for mark: Any? in [nil, "yes"] {
            var coordinator: [String: Any] = ["id": coordinatorID.uuidString, "title": "Coordinator", "panels": []]
            coordinator["isCoordinator"] = mark
            let older = try GatewayCompatibilityDecoder().decodeSessionListResponse(snapshotData(
                workspaces: [["id": projectID.uuidString, "title": "toastty", "panels": []], coordinator],
                tasks: [:]
            )).presentation()
            XCTAssertNotNil(older.taskBoard)
            XCTAssertNil(older.coordinator, "mark: \(String(describing: mark))")
            XCTAssertNil(older.workspaces.first { $0.id == coordinatorID }?.coordinatorConversationID)
            XCTAssertEqual(Set(older.topLevelWorkspaces.map(\.id)), [projectID, coordinatorID])
        }
    }

    /// The coordinator's workspace carries the read point of the
    /// coordinator's chat. An older Mac sends none, and one this phone
    /// cannot read counts as none, so the chat shows no New line.
    func testTheCoordinatorsReadPointDecodesAndAnOlderOrMalformedOneIsNone() throws {
        let coordinatorID = UUID()
        func decoded(_ read: Any?) throws -> MobileHomeSnapshot {
            var coordinator: [String: Any] = [
                "id": coordinatorID.uuidString, "title": "Coordinator", "panels": [], "isCoordinator": true,
            ]
            coordinator["coordinatorChatRead"] = read
            return try GatewayCompatibilityDecoder().decodeSessionListResponse(snapshotData(
                workspaces: [coordinator], tasks: [:]
            )).presentation()
        }
        let read = try decoded(["eventID": "claude:msg_7", "timestamp": "2026-09-06T12:00:00.250Z"])
        XCTAssertEqual(read.coordinatorChatRead, RemoteCoordinatorChatReadPoint(
            eventID: "claude:msg_7", timestamp: Date(timeIntervalSince1970: 1_788_696_000.25)
        ))
        // A read point that an older Toastty saved names no event.
        XCTAssertNil(try decoded(["timestamp": "2026-09-06T12:00:00.250Z"]).coordinatorChatRead?.eventID)
        XCTAssertNotNil(try decoded(["timestamp": "2026-09-06T12:00:00.250Z"]).coordinatorChatRead)
        // A runtime event's identity does not survive a Mac relaunch.
        XCTAssertNil(try decoded(["eventID": "rt:1:4", "timestamp": "2026-09-06T12:00:00.250Z"]).coordinatorChatRead?.eventID)
        for value: Any? in [nil, "yes", ["eventID": "claude:msg_7"], ["timestamp": 12]] {
            let snapshot = try decoded(value)
            XCTAssertNotNil(snapshot.coordinator)
            XCTAssertNil(snapshot.coordinatorChatRead, "value: \(String(describing: value))")
        }
    }

    /// The coordinator's workspace carries the revision of its quiet wake
    /// turns. An older Mac sends none, and one this phone cannot read
    /// counts as none, so no turn folds.
    func testTheQuietDigestsRevisionDecodesAndAnOlderOrMalformedOneIsNone() throws {
        let coordinatorID = UUID()
        func decoded(_ revision: Any?) throws -> MobileHomeSnapshot {
            var coordinator: [String: Any] = [
                "id": coordinatorID.uuidString, "title": "Coordinator", "panels": [], "isCoordinator": true,
            ]
            coordinator["coordinatorQuietDigestsRevision"] = revision
            return try GatewayCompatibilityDecoder().decodeSessionListResponse(snapshotData(
                workspaces: [coordinator], tasks: [:]
            )).presentation()
        }
        XCTAssertEqual(try decoded("6ca155390421e7e6").coordinatorQuietDigestsRevision, "6ca155390421e7e6")
        for value: Any? in [nil, 7, ["revision": "6ca155390421e7e6"]] {
            let snapshot = try decoded(value)
            XCTAssertNotNil(snapshot.coordinator)
            XCTAssertNil(snapshot.coordinatorQuietDigestsRevision, "value: \(String(describing: value))")
        }
    }

    /// The phone finds a digest's key from the text that the Mac's
    /// conversation reader sends. The text crosses the wire exactly: white
    /// space, line endings, non-ASCII text and characters that JSON escapes
    /// keep the key that the Mac computes from its own copy of the text.
    func testADigestCrossingTheWireKeepsTheMacsKey() throws {
        let header = "\(CoordinatorMessageHeader.digestPrefix): this message is from Toastty, not from the user."
        let texts = [
            header + "\n- [Fix the login](toastty://task/1): needsYou (review) at 2026-11-16T15:25:00Z\nRead `toastty task list` for details.",
            "\n  " + header + "\r\n- [Café \u{1F35E} \"quoted\" \\ back/slash](toastty://task/2): idle\r\n\t\n",
            header + "\n- [e\u{0301} and \u{00E9}, \u{2028} \u{2029} \u{0007}](toastty://task/3): running",
        ]
        let conversationID = RemoteConversationID(rawValue: UUID())
        let events = texts.enumerated().map { index, text in
            ConversationEvent(
                conversationID: conversationID, sequence: UInt64(index + 1), eventID: "claude:msg_\(index)",
                timestamp: Date(timeIntervalSince1970: 1_800_000_000), provider: .claude,
                payload: .userMessage(.init(text: text, origin: .remote))
            )
        }
        let page = ConversationEventPage(
            conversationID: conversationID, projectionRunID: RemoteProjectionRunID(rawValue: UUID()),
            projectionGeneration: 1, events: events, latestSequence: 3, firstAvailableSequence: 1
        )
        // The bytes the Mac's gateway writes, read by this phone's decoder.
        let bytes = try ConversationEventCoding.makeEncoder().encode(RemoteGatewayEventsResponse.page(page))
        guard case .page(let decoded) = try GatewayCompatibilityDecoder().decodeEventsResponse(bytes) else {
            return XCTFail("The page did not decode")
        }
        let received = decoded.events.compactMap { event -> String? in
            guard case .known(let known) = event, case .userMessage(let message) = known.payload else { return nil }
            return message.text
        }
        XCTAssertEqual(received.map(CoordinatorMessageHeader.digestKey), texts.map(CoordinatorMessageHeader.digestKey))
        XCTAssertEqual(Set(texts.map(CoordinatorMessageHeader.digestKey)).count, texts.count)
    }

    private func snapshotData(workspaces: [[String: Any]]?, tasks: [String: Any]? = nil) throws -> Data {
        var snapshot: [String: Any] = ["projectionRunID": UUID().uuidString, "conversations": [],
                                        "generatedAt": "2026-09-06T12:00:00.000Z"]
        if let workspaces { snapshot["workspaces"] = workspaces }
        if let tasks { snapshot["tasks"] = tasks }
        return try JSONSerialization.data(withJSONObject: ["protocolVersion": "1.0", "snapshot": snapshot])
    }
}
