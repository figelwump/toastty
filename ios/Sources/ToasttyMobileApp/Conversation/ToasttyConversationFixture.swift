#if DEBUG
import ConversationUI
import Foundation
import RemoteProtocol
import ToasttyMobileDomain

enum ToasttyConversationFixture {
    enum EntryLoad: String, Equatable, Sendable {
        case catchUp = "catch-up"
        case phaseOnly = "phase-only"
        case rebuilt
        case reconnect
    }

    static func entryLoadHome(isRead: Bool = false) -> MobileHomeSnapshot {
        let workspaceID = ToasttyMobileFixture.previewWorkspaceID
        let conversations = [1, 7].map { number in
            MobileConversation(
                id: UUID(uuidString: String(format: "B1000000-0000-0000-0000-%012d", number))!,
                workspaceID: workspaceID, workspaceTitle: "toastty", cwd: nil, agent: .codex,
                title: number == 1 ? "Mobile gateway design" : "Changelog + tag",
                state: number == 1 ? MobileSessionStatus.needsApproval : (isRead ? .idle : .ready),
                inputAvailability: .unavailable(reason: "fixture"), age: "now", lastActivity: "Entry loading fixture"
            )
        }
        return MobileHomeSnapshot(hostName: "Fixture Mac", workspaces: [
            MobileWorkspace(id: workspaceID, title: "toastty", conversations: conversations),
        ])
    }

    static func entryLoadPresentation(
        for conversationID: UUID, mode: EntryLoad, step: Int
    ) -> ToasttyConversationPresentationState {
        let timestamp = Date(timeIntervalSince1970: 0)
        let longText = (1...28).map {
            "Paragraph \($0). This response has enough text to keep its start and end in different viewports. The reader can scroll through it."
        }.joined(separator: "\n\n")
        var rows = [
            row(conversationID, 1, timestamp, .userMessage(text: "Previous request", origin: .local)),
            row(conversationID, 2, timestamp, .assistantMessage(text: "## PREVIOUS RESPONSE\n\n" + longText, phase: .final)),
        ]
        if step > 0 || mode == .phaseOnly {
            rows += [
                row(conversationID, 3, timestamp, .userMessage(text: "Latest request", origin: .local)),
                row(conversationID, 4, timestamp, .assistantMessage(text: "## LATEST RESPONSE\n\n" + longText, phase: .final)),
            ]
        }
        if mode == .rebuilt, step == 2 {
            rows = rows.map { row in
                ToasttyTranscriptRow(
                    id: ToasttyTranscriptRowID(
                        projectionRunID: row.id.projectionRunID, projectionGeneration: 2,
                        conversationID: conversationID, sequence: row.id.sequence
                    ),
                    timestamp: row.timestamp, provider: row.provider, content: row.content
                )
            }
        }
        let revision: ToasttyTranscriptRevision = switch (mode, step) {
        case (.phaseOnly, _), (_, 0): .initial
        case (.rebuilt, 2): .rebuilt
        case (_, 1): .appended
        default: .metadataOnly
        }
        return ToasttyConversationPresentationState(
            rows: rows,
            phase: step == 2 ? .live : (mode == .reconnect ? .stale : .resyncing),
            revision: revision, historyTruncated: false
        )
    }

    enum SendEventOrder: String {
        case statusFirst = "status-first"
        case echoFirst = "echo-first"

        func hasWorkingStatus(after updateCount: Int) -> Bool {
            updateCount >= (self == .statusFirst ? 1 : 2) && updateCount < 5
        }

        func hasCanonicalEcho(after updateCount: Int) -> Bool {
            updateCount >= (self == .statusFirst ? 2 : 1)
        }
    }

    static let questionInteractionID = RemotePendingInteraction.ID(
        rawValue: "fixture-question-interaction"
    )
    static let questionResponseID = "fixture-question-response"
    static let questionEpoch = RemoteInputEpoch(
        bindingID: UUID(uuidString: "D1000000-0000-0000-0000-000000000099")!,
        counter: 12
    )
    static let questions = [
        RemoteInteractionQuestion(
            id: "0",
            header: "Approach",
            question: "Which implementation should Claude use?",
            options: [
                .init(
                    id: "0",
                    label: "Small change",
                    detail: "Keep the current data flow",
                    preview: "Controller → semantic request → host"
                ),
                .init(id: "1", label: "Broad refactor", detail: "Replace the surrounding feature"),
            ]
        ),
        RemoteInteractionQuestion(
            id: "1",
            header: "Checks",
            question: "Which checks should run?",
            options: [
                .init(id: "0", label: "Domain tests"),
                .init(id: "1", label: "UI test"),
                .init(id: "2", label: "Remote build"),
            ],
            multiSelect: true
        ),
        RemoteInteractionQuestion(
            id: "2",
            header: "Release note",
            question: "What should the release note say?",
            options: [
                .init(id: "0", label: "Use the standard note"),
                .init(id: "1", label: "Skip the note"),
            ]
        ),
    ]
    /// Set with the interaction-answer scenario to show a Claude permission
    /// request instead of the question form.
    static var usesPermissionRequest: Bool {
        ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_PERMISSION"] == "1"
    }
    static let permissionCommand = """
        xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp \\
          -destination 'platform=macOS,arch=arm64' -derivedDataPath Derived test \\
          -only-testing:ToasttyAppTests/ClaudePermissionBrokerTests
        """
    static let permissionQuestion = RemoteInteractionQuestion(
        id: "decision",
        header: "Bash",
        question: "Approve Running xcodebuild -workspace toastty.xcworkspace\n\n\(permissionCommand)",
        options: [
            .init(id: "allow", label: "Allow once"),
            .init(id: "always:0", label: "Always allow Bash(xcodebuild -workspace:*)",
                  detail: "Saved for this project in .claude/settings.local.json"),
            .init(id: "deny", label: "Deny", detail: "Stops Claude so you can say what to do instead"),
        ]
    )
    static var answerQuestions: [RemoteInteractionQuestion] {
        usesPermissionRequest ? [permissionQuestion] : questions
    }
    private static let projectionRunID = UUID(
        uuidString: "D2000000-0000-0000-0000-000000000001"
    )!
    private static let projectionGeneration: UInt64 = 1

    static func presentation(
        for conversationID: UUID,
        phase: ToasttyConversationPresentationPhase = .live
    ) -> ToasttyConversationPresentationState {
        let timestamp = Date(timeIntervalSince1970: 1_786_406_400)
        let interactionID = RemotePendingInteraction.ID(rawValue: "fixture-interaction")
        let interaction = RemotePendingInteraction(
            id: interactionID,
            kind: .structuredChoice,
            providerCallID: "fixture-call",
            prompt: "Choose the safe rollout strategy on your Mac",
            options: [
                .init(id: "canary", label: "Canary", detail: "Roll out to one workspace first"),
                .init(id: "all", label: "All workspaces", detail: "Apply the change everywhere"),
            ],
            inputEpoch: RemoteInputEpoch(
                bindingID: UUID(uuidString: "D1000000-0000-0000-0000-000000000001")!,
                counter: 7
            ),
            presentedAt: timestamp,
            state: .pending
        )
        var resolvedInteraction = interaction
        resolvedInteraction.state = .resolved
        var currentInteraction = interaction
        currentInteraction.id = RemotePendingInteraction.ID(rawValue: "fixture-interaction-current")
        let longMessage = Array(
            repeating: "This deliberately long transcript fixture validates full rendering and dynamic layout.",
            count: 23
        ).joined(separator: " ") + " Full transcript tail remains visible."

        return ToasttyConversationPresentationState(
            rows: [
                row(conversationID, 1, timestamp, .sessionBindingChanged(reason: .runtimeBound)),
                row(
                    conversationID,
                    2,
                    timestamp,
                    .userMessage(
                        text: "Extract the gateway protocol and keep the mobile interaction surface read-only.",
                        origin: .local
                    )
                ),
                row(
                    conversationID,
                    3,
                    timestamp,
                    .assistantMessage(
                        text: "I’ll inspect the shared contract, then implement the transcript against stable journal sequences.",
                        phase: .commentary
                    )
                ),
                row(
                    conversationID,
                    4,
                    timestamp,
                    .toolStarted(
                        callID: "fixture-tool-1",
                        name: "Read",
                        detail: "Sources/RemoteProtocol/ConversationEvent.swift"
                    )
                ),
                row(
                    conversationID,
                    5,
                    timestamp,
                    .toolFinished(
                        callID: "fixture-tool-1",
                        name: "Read",
                        outcome: .succeeded,
                        detail: "Loaded 357 lines"
                    )
                ),
                row(
                    conversationID,
                    6,
                    timestamp,
                    .subagentSummary(
                        name: "Transcript QA",
                        phase: .updated,
                        detail: "Exercising every event kind and large Dynamic Type."
                    )
                ),
                row(
                    conversationID,
                    7,
                    timestamp,
                    .interaction(ToasttyInteractionPresentation(interaction: resolvedInteraction))
                ),
                row(
                    conversationID,
                    9,
                    timestamp,
                    .interactionResolved(interactionID: interactionID, resolution: .resolved)
                ),
                row(conversationID, 10, timestamp, .sessionBindingChanged(reason: .runtimeResumed)),
                row(
                    conversationID,
                    11,
                    timestamp,
                    .assistantMessage(
                        text: "## Transcript ready\n\nKnown events render in sequence with **stable identity** and read-only interaction choices.\n\nOpen [docs/mobile-preview.md:12](docs/mobile-preview.md:12) or the [HTML sample](site/preview.html).",
                        phase: .final
                    )
                ),
                row(
                    conversationID,
                    12,
                    timestamp,
                    .userMessage(text: "This message came from a paired mobile device.", origin: .remote)
                ),
                row(
                    conversationID,
                    13,
                    timestamp,
                    .assistantMessage(text: longMessage, phase: .final)
                ),
                row(
                    conversationID,
                    14,
                    timestamp,
                    .interaction(ToasttyInteractionPresentation(interaction: currentInteraction))
                ),
            ],
            phase: phase,
            revision: .initial,
            historyTruncated: false
        )
    }

    static func responseEntryPresentation(
        for conversationID: UUID,
        hasWork: Bool,
        hasLongHistory: Bool
    ) -> ToasttyConversationPresentationState {
        let fixture = presentation(for: conversationID)
        let historyCount: UInt64 = hasLongHistory ? 200 : 0
        var rows: [ToasttyTranscriptRow] = (0 ..< historyCount).map { index in
            row(conversationID, index + 1, Date(timeIntervalSince1970: 1_786_406_400),
                .assistantMessage(text: "Earlier response \(index + 1)", phase: .final))
        }
        for original in fixture.rows {
            if hasWork, original.id.sequence == 13 {
                rows.append(row(conversationID, historyCount + 13, original.timestamp,
                    .toolStarted(callID: "response-check", name: "Read", detail: nil)))
                rows.append(row(conversationID, historyCount + 14, original.timestamp,
                    .toolFinished(callID: "response-check", name: "Read", outcome: .succeeded, detail: nil)))
            }
            rows.append(row(
                conversationID,
                historyCount + original.id.sequence + (hasWork && original.id.sequence >= 13 ? 2 : 0),
                original.timestamp,
                original.content
            ))
        }
        return ToasttyConversationPresentationState(
            rows: rows, phase: .live, revision: .initial, historyTruncated: false
        )
    }

    static func performancePresentation(
        for conversationID: UUID
    ) -> ToasttyConversationPresentationState {
        let timestamp = Date(timeIntervalSince1970: 1_786_406_400)
        let rows = (1 ... 5_000).map { sequence in
            row(
                conversationID,
                UInt64(sequence),
                timestamp,
                sequence.isMultiple(of: 3)
                    ? .userMessage(text: "Fixture user message \(sequence)", origin: .local)
                    : .assistantMessage(text: "Fixture assistant response \(sequence)", phase: .final)
            )
        }
        return ToasttyConversationPresentationState(
            rows: rows,
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )
    }

    /// `responses` adds that many answers that arrived after the fixture's
    /// transcript, as the incoming fixture delivers them.
    static func gatedSendPresentation(
        for conversationID: UUID,
        sendItems: [ToasttySendPresentationItem],
        hasShortResponse: Bool = false,
        responses: Int = 0
    ) -> ToasttyConversationPresentationState {
        let fixture = presentation(for: conversationID)
        let timestamp = Date(timeIntervalSince1970: 1_786_406_400)
        let incoming = (0..<max(0, responses)).map { index in
            row(conversationID, UInt64(101 + index), timestamp, .assistantMessage(
                text: incomingResponseText(index + 1), phase: .final
            ))
        }
        return ToasttyConversationPresentationState(
            rows: fixture.rows.filter { $0.id.sequence != 14 }.map { row in
                guard hasShortResponse, row.id.sequence == 13 else { return row }
                return ToasttyTranscriptRow(
                    id: row.id, timestamp: row.timestamp, provider: row.provider,
                    content: .assistantMessage(text: "The latest response is ready.", phase: .final)
                )
            } + incoming,
            sendItems: sendItems,
            phase: .live,
            revision: sendItems.isEmpty && responses == 0 ? .initial : .appended,
            historyTruncated: false
        )
    }

    static func incomingResponseText(_ number: Int) -> String {
        "Incoming response \(number): the checks passed on the remote test Mac."
    }

    static func reconciledSendPresentation(
        for conversationID: UUID,
        sendItems: [ToasttySendPresentationItem],
        sentText: String?,
        updateCount: Int,
        order: SendEventOrder
    ) -> ToasttyConversationPresentationState {
        let timestamp = Date(timeIntervalSince1970: 1_786_406_400)
        var rows = [
            row(conversationID, 1, timestamp, .userMessage(text: "Previous request", origin: .local)),
            row(conversationID, 2, timestamp, .assistantMessage(
                text: Array(repeating: "Earlier work details must stay collapsed during the next send.", count: 30)
                    .joined(separator: "\n\n"),
                phase: .commentary
            )),
            row(conversationID, 3, timestamp, .assistantMessage(text: "The previous request is complete.", phase: .final)),
        ]
        if let sentText, order.hasCanonicalEcho(after: updateCount) {
            rows.append(row(conversationID, 4, timestamp, .userMessage(text: sentText, origin: .remote)))
        }
        if updateCount >= 3 {
            rows.append(row(conversationID, 5, timestamp, .assistantMessage(text: "Working on the new request.", phase: .commentary)))
        }
        if updateCount >= 4 {
            rows.append(row(conversationID, 6, timestamp, .assistantMessage(text: "The new answer is ready.", phase: .final)))
        }
        let contentChanged = updateCount == (order == .statusFirst ? 2 : 1)
            || updateCount == 3 || updateCount == 4
        return ToasttyConversationPresentationState(
            rows: rows,
            sendItems: sendItems,
            phase: .live,
            revision: sentText == nil ? .initial : (contentChanged ? .appended : .metadataOnly),
            historyTruncated: false
        )
    }

    static func questionPresentation(
        for conversationID: UUID,
        answers: [RemoteInteractionAnswer]? = nil
    ) -> ToasttyConversationPresentationState {
        let timestamp = Date(timeIntervalSince1970: 1_786_406_400)
        let state: RemotePendingInteraction.State = answers == nil ? .pending : .resolved
        let permission = usesPermissionRequest
        // A permission resolves without accepted answers: no provider fact
        // says which decision won, so the phone shows only what it sent.
        let interaction = RemotePendingInteraction(
            id: questionInteractionID,
            kind: permission ? .permission : .question,
            providerCallID: "fixture-question-call",
            prompt: permission
                ? "Approve Running xcodebuild -workspace toastty.xcworkspace"
                : "Claude needs your answers before it can continue.",
            inputEpoch: questionEpoch,
            presentedAt: timestamp,
            state: state,
            questions: answerQuestions,
            responseID: answers == nil ? questionResponseID : nil,
            responseExpiresAt: Date(timeIntervalSince1970: 1_786_410_000),
            answers: permission ? nil : answers,
            permission: permission
                ? RemotePermissionRequestDetail(toolName: "Bash", description: "Run the permission broker tests",
                                                preview: permissionCommand)
                : nil
        )
        var rows = [
            row(
                conversationID,
                1,
                timestamp,
                .assistantMessage(text: "I need a few choices before I continue.", phase: .commentary)
            ),
            row(
                conversationID,
                2,
                timestamp,
                .interaction(ToasttyInteractionPresentation(interaction: interaction))
            ),
        ]
        if answers != nil {
            rows.append(row(
                conversationID,
                3,
                timestamp,
                .interactionResolved(interactionID: questionInteractionID, resolution: .resolved)
            ))
        }
        return ToasttyConversationPresentationState(
            rows: rows,
            phase: .live,
            revision: answers == nil ? .initial : .appended,
            historyTruncated: false
        )
    }

    /// A conversation whose middle assistant message is far above the chunking
    /// threshold, exercising chunked rendering and live-edge jumps over a
    /// transcript dominated by one giant message.
    static func longMessagePresentation(
        for conversationID: UUID
    ) -> ToasttyConversationPresentationState {
        let timestamp = Date(timeIntervalSince1970: 1_786_406_400)
        // Big enough to split into several chunks, small enough that XCUITest
        // accessibility snapshots of the transcript stay fast.
        let sections = (1 ... 10).map { index in
            """
            ## Deep dive \(index)

            Chunked rendering keeps giant transcripts scrollable because every \
            slice is measured independently while the markdown stays valid \
            across the seams. Section \(index) repeats enough body text that \
            the message far exceeds a single chunk budget.
            """
        }
        let fence = (["```swift"]
            + (1 ... 30).map { "let fixtureValue\($0) = transcriptFixtureValue(\($0))" }
            + ["```"]).joined(separator: "\n")
        let giantMessage = (sections + [fence]).joined(separator: "\n\n")

        return ToasttyConversationPresentationState(
            rows: [
                row(conversationID, 1, timestamp, .sessionBindingChanged(reason: .runtimeBound)),
                row(
                    conversationID,
                    2,
                    timestamp,
                    .userMessage(text: "Walk me through the whole subsystem in detail.", origin: .local)
                ),
                row(conversationID, 3, timestamp, .assistantMessage(text: giantMessage, phase: .final)),
                row(
                    conversationID,
                    4,
                    timestamp,
                    .assistantMessage(text: "That covers every layer end to end.", phase: .final)
                ),
            ],
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )
    }

    static func tablePresentation(
        for conversationID: UUID
    ) -> ToasttyConversationPresentationState {
        let timestamp = Date(timeIntervalSince1970: 1_786_406_400)
        let markdown = """
        ## Responsibility overview

        | Component | Responsibility |
        | :--- | :--- |
        | Gateway | Routes authenticated requests to the correct workspace. |
        | Mobile | Renders **conversation** updates and `send` results. |

        ## Wide comparison

        | Name | State | Count | Details |
        | :--- | :---: | ---: | :--- |
        | Alpha | Ready | 12 | Final column is readable. |
        | Beta | Waiting | 7 | All cells stay aligned. |
        """
        return ToasttyConversationPresentationState(
            rows: [row(conversationID, 1, timestamp, .assistantMessage(text: markdown, phase: .final))],
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )
    }

    /// The coordinator's answer with task links, for the task fixture's
    /// board: three tasks it lists, a task it does not list, a task space
    /// with no task record, and another Toastty link. Link text is the title
    /// at the time of writing; a chip shows the task's current title.
    static func taskLinkPresentation(
        for conversationID: UUID
    ) -> ToasttyConversationPresentationState {
        let timestamp = Date(timeIntervalSince1970: 1_786_406_400)
        func link(_ title: String, _ id: UUID) -> String {
            "[\(title)](toastty://task/\(id.uuidString))"
        }
        let markdown = """
        Yes, it waits for \(link("Should the badge count tasks?", ToasttyMobileFixture.questionTaskID)). \
        \(link("Compact session rows", ToasttyMobileFixture.reviewTaskID)) has its pull request open, \
        and \(link("Parent task rollup", ToasttyMobileFixture.shippedTaskID)) merged.

        These stay text: \(link("Removed task", UUID(uuidString: "99999999-9999-4999-8999-999999999999")!)), \
        \(link("Watched space", ToasttyMobileFixture.workingSubspaceID)) and \
        [a settings link](toastty://action/open-settings).
        """
        return ToasttyConversationPresentationState(
            rows: [
                row(conversationID, 1, timestamp, .userMessage(text: "Is the badge task blocked?", origin: .remote)),
                row(conversationID, 2, timestamp, .assistantMessage(text: markdown, phase: .final)),
            ],
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )
    }

    /// A task the Mac's board does not list, so its link stays text.
    static let unlistedTaskID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

    /// The coordinator's chat, as in the proposal's mockup A, from the
    /// events that the Mac sends: a digest that Toastty typed, the
    /// coordinator's answer with task links, a task's message that
    /// `coordinator send` brought, a reply to the coordinator, and a quick
    /// entry message with its choices and a file. They show as the Mac's
    /// coordinator chat shows them.
    /// `hasLongMessage` ends the chat with a coordinator message long
    /// enough that the transcript draws it as several rows.
    /// `quietTurns` ends it with two wake turns that the coordinator marked
    /// quiet, as in the user's report, and says whether the fixture Mac
    /// shares the marks.
    static func coordinatorPresentation(
        for conversationID: UUID,
        sendItems: [ToasttySendPresentationItem] = [],
        hasLongMessage: Bool = false,
        quietTurns: CoordinatorQuietTurns = .none,
        wakeTurns: Int = 0,
        responses: Int = 0
    ) -> ToasttyConversationPresentationState {
        ToasttyConversationPresentationAdapter.makeState(
            events: coordinatorEvents(
                for: conversationID, hasLongMessage: hasLongMessage, quietTurns: quietTurns,
                wakeTurns: wakeTurns, responses: responses
            )
                .map(CompatibleConversationEvent.known),
            projectionRunID: RemoteProjectionRunID(rawValue: projectionRunID),
            projectionGeneration: projectionGeneration,
            phase: .live,
            revision: responses == 0 ? .initial : .appended,
            historyTruncated: false,
            sendItems: sendItems,
            coordinatorMessages: ToasttyConversationPresentationAdapter.coordinatorMessages(
                quietDigestKeys: quietTurns == .shared ? coordinatorQuietDigestKeys : nil
            )
        )
    }

    /// The fixture coordinator chat's quiet wake turns.
    enum CoordinatorQuietTurns: Equatable {
        case none
        /// The turns, and a Mac that shares which are quiet.
        case shared
        /// The turns, and an older Mac that does not share the marks.
        case unshared
    }

    /// The digests of the fixture's quiet wake turns, which a fixture Mac
    /// that shares the marks names by their keys.
    static let coordinatorQuietDigests = [
        """
        \(CoordinatorMessageHeader.digestPrefix): this message is from Toastty, not from the user.
        - [compact-session-rows](toastty://task/\(ToasttyMobileFixture.reviewTaskID.uuidString)): idle at 2026-08-11T15:21:40Z
        Read `toastty task list` for details.
        """,
        """
        \(CoordinatorMessageHeader.digestPrefix): this message is from Toastty, not from the user.
        - [early-session-titles](toastty://task/\(ToasttyMobileFixture.questionTaskID.uuidString)): running at 2026-08-11T15:27:05Z
        Read `toastty task list` for details.
        """,
    ]

    /// The digest of the fixture's wake turn `index`.
    static func wakeDigest(_ index: Int) -> String {
        """
        \(CoordinatorMessageHeader.digestPrefix): this message is from Toastty, not from the user.
        - [wake-task-\(index + 1)](toastty://task/\(ToasttyMobileFixture.reviewTaskID.uuidString)): running at 2026-08-11T15:\(10 + index % 50):00Z
        Read `toastty task list` for details.
        """
    }

    static var coordinatorQuietDigestKeys: Set<String> {
        Set(coordinatorQuietDigests.map(CoordinatorChatTranscript.digestKey))
    }

    /// Each quiet turn's answer, as in the user's report.
    static let coordinatorQuietAnswers = ["Nothing new needs you.", "Nothing needs you."]

    /// The opening and the last line of the long message that
    /// `hasLongMessage` adds.
    static let coordinatorLongMessageOpening = "Here is the week, task by task."
    static let coordinatorLongMessageEnding = "That is everything that moved this week."

    static func coordinatorEvents(
        for conversationID: UUID,
        hasLongMessage: Bool = false,
        quietTurns: CoordinatorQuietTurns = .none,
        wakeTurns: Int = 0,
        responses: Int = 0
    ) -> [ConversationEvent] {
        // Event `n` is `n - 1` times two minutes after the first.
        func time(_ sequence: Int) -> Date {
            Date(timeIntervalSince1970: 1_786_406_400).addingTimeInterval(TimeInterval((sequence - 1) * 2 * 60))
        }
        func link(_ title: String, _ id: UUID) -> String {
            "[\(title)](toastty://task/\(id.uuidString))"
        }
        let digest = """
        \(CoordinatorMessageHeader.digestPrefix): this message is from Toastty, not from the user.
        - \(link("compact-session-rows", ToasttyMobileFixture.reviewTaskID)): needsYou (review) at 2026-08-11T14:04:10Z
        - \(link("Parent task rollup", ToasttyMobileFixture.shippedTaskID)): toShip, merged at 2026-08-11T14:04:40Z
        Read `toastty task list` for details.
        """
        let fromTask = CoordinatorMessageHeader.message(
            from: .task(id: ToasttyMobileFixture.questionTaskID, title: "early-session-titles"),
            text: "Done the first pass. Should the old API stay for one release?"
        )
        let answer = "I asked it to keep the old API until the next release, as your policy says."
        // The reply quotes the answer, event 4, by its time.
        let reply = CoordinatorMessageHeader.replyMessage(
            quote: answer,
            time: ToasttyConversationPresentationAdapter.coordinatorMessages().timeText(time(4)),
            text: "Good. Release toastty once the export API merges."
        )
        let quickEntry = CoordinatorMessageHeader.quickEntryMessage(
            CoordinatorMessageHeader.QuickEntry(
                project: .init(id: ToasttyMobileFixture.previewWorkspaceID, title: "toastty"),
                agent: "codex", model: "gpt-6.1-sol", effort: "high"
            ),
            text: "Add a CSV export to the Tasks tab, like this mockup.",
            attachmentPaths: ["/Users/me/.toastty/coordinator/attachments/A1/csv-mockup.png"]
        )
        // Over the transcript's chunk threshold, so it draws as several rows.
        let longMessage = ([coordinatorLongMessageOpening] + (1...20).map { index in
            "Task \(index) moved from Running to Ready to review after its checks passed on the remote test Mac. "
                + "Its agent wrote the report, opened the pull request and asked for a review, and nothing waits for you."
        } + [coordinatorLongMessageEnding]).joined(separator: "\n\n")
        var payloads: [ConversationEventPayload] = [
            .userMessage(.init(text: digest, origin: .remote)),
            .assistantMessage(.init(
                text: "Two tasks moved. \(link("Compact session rows", ToasttyMobileFixture.reviewTaskID)) "
                    + "is ready for review, and \(link("Parent task rollup", ToasttyMobileFixture.shippedTaskID)) merged.",
                phase: .final
            )),
            .userMessage(.init(text: fromTask, origin: .remote)),
            .assistantMessage(.init(text: answer, phase: .final)),
            .userMessage(.init(text: reply, origin: .remote)),
            .assistantMessage(.init(
                text: "Noted. I will start the release right after it merges. "
                    + "\(link("Early titles", ToasttyMobileFixture.questionTaskID)) keeps the old API for now. "
                    + "\(link("Old export spike", unlistedTaskID)) was archived, so it stays out.",
                phase: .final
            )),
            .userMessage(.init(text: quickEntry, origin: .remote)),
            .assistantMessage(.init(text: "I made a task for it in toastty, with Codex.", phase: .final)),
        ]
        // A long chat, as a coordinator's grows: wake turns that each read
        // the tasks and answer, at different lengths.
        for index in 0..<max(0, wakeTurns) {
            payloads.append(.userMessage(.init(text: wakeDigest(index), origin: .remote)))
            let callID = "wake-\(index + 1)"
            payloads.append(.toolStarted(.init(callID: callID, toolName: "Bash", detail: "toastty task list")))
            payloads.append(.toolFinished(.init(callID: callID, toolName: "Bash", outcome: .succeeded)))
            let sentence = "Task \(index + 1) is still running its checks on the remote test Mac, and nothing waits for you. "
            payloads.append(.assistantMessage(.init(
                text: "Wake \(index + 1). " + String(repeating: sentence, count: 1 + index % 4),
                phase: .final
            )))
        }
        if hasLongMessage {
            payloads.append(.userMessage(.init(text: "What moved this week?", origin: .remote)))
            payloads.append(.assistantMessage(.init(text: longMessage, phase: .final)))
        }
        if quietTurns != .none {
            // Each wake turn reads the tasks, finds nothing for the user and
            // says so with `coordinator wake --quiet`.
            for (index, digest) in coordinatorQuietDigests.enumerated() {
                payloads.append(.userMessage(.init(text: digest, origin: .remote)))
                for (call, command) in ["toastty task list", "toastty coordinator wake --clear --quiet"].enumerated() {
                    let callID = "quiet-\(index + 1)-\(call + 1)"
                    payloads.append(.toolStarted(.init(callID: callID, toolName: "Bash", detail: command)))
                    payloads.append(.toolFinished(.init(callID: callID, toolName: "Bash", outcome: .succeeded)))
                }
                payloads.append(.assistantMessage(.init(text: coordinatorQuietAnswers[index], phase: .final)))
            }
        }
        payloads += (0..<max(0, responses)).map { index -> ConversationEventPayload in
            .assistantMessage(.init(text: incomingResponseText(index + 1), phase: .final))
        }
        return payloads.enumerated().map { index, payload in
            ConversationEvent(
                conversationID: RemoteConversationID(rawValue: conversationID),
                sequence: UInt64(index + 1),
                eventID: "coordinator-fixture-\(index + 1)",
                timestamp: time(index + 1),
                provider: .claude,
                payload: payload
            )
        }
    }

    static func toolActivityPresentation(
        for conversationID: UUID
    ) -> ToasttyConversationPresentationState {
        let fixture = presentation(for: conversationID)
        return ToasttyConversationPresentationState(
            rows: fixture.rows.filter { [4, 5].contains($0.id.sequence) },
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )
    }

    static func truncatedPresentation(
        for conversationID: UUID
    ) -> ToasttyConversationPresentationState {
        let fixture = presentation(for: conversationID)
        return ToasttyConversationPresentationState(
            rows: fixture.rows,
            phase: fixture.phase,
            revision: fixture.revision,
            historyTruncated: true
        )
    }

    static func pagedPresentation(
        for conversationID: UUID,
        hasLoadedOlder: Bool
    ) -> ToasttyConversationPresentationState {
        let fixture = presentation(for: conversationID)
        let tailRows = Array(fixture.rows.suffix(6))
        return ToasttyConversationPresentationState(
            rows: hasLoadedOlder ? fixture.rows : tailRows,
            phase: fixture.phase,
            revision: hasLoadedOlder ? .prepended : .initial,
            historyTruncated: false,
            hasOlder: hasLoadedOlder == false,
            prependAnchorID: hasLoadedOlder ? tailRows.first?.id : nil
        )
    }

    private static func row(
        _ conversationID: UUID,
        _ sequence: UInt64,
        _ timestamp: Date,
        _ content: ToasttyTranscriptRow.Content
    ) -> ToasttyTranscriptRow {
        ToasttyTranscriptRow(
            id: ToasttyTranscriptRowID(
                projectionRunID: projectionRunID,
                projectionGeneration: projectionGeneration,
                conversationID: conversationID,
                sequence: sequence
            ),
            timestamp: timestamp.addingTimeInterval(TimeInterval(sequence)),
            provider: .codex,
            content: content
        )
    }
}
#endif
