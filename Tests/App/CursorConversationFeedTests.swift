import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

@MainActor
struct CursorConversationFeedTests {
    @MainActor
    private final class Fixture {
        let store = SessionRuntimeStore()
        let sessionID = "cursor-feed-test"
        let panelID = UUID()
        var date = Date(timeIntervalSince1970: 1_786_000_000)

        init() {
            store.startSession(
                sessionID: sessionID, agent: .cursor, panelID: panelID,
                windowID: UUID(), workspaceID: UUID(), cwd: "/repo", repoRoot: "/repo", at: date
            )
        }

        @discardableResult
        func send(
            _ name: String, conversation: String = "root", generation: String? = nil,
            text: String? = nil, cloud: Bool = false, status: SessionStatusKind? = nil
        ) -> Bool {
            date = date.addingTimeInterval(1)
            return store.handleCursorHookEvent(
                sessionID: sessionID,
                event: CursorHookEvent(
                    hookEventName: name, conversationID: conversation, generationID: generation,
                    cloudHandoff: cloud,
                    status: status.map { SessionStatus(kind: $0, summary: $0.rawValue) },
                    text: text
                ),
                at: date
            )
        }

        func feed() throws -> ManagedProviderConversationFeedSnapshot {
            try #require(store.providerConversationFeed(managedSessionID: sessionID))
        }

        func start() {
            send("sessionStart", status: .idle)
            send("beforeSubmitPrompt", generation: "turn-1", text: "Explain this change", status: .working)
        }
    }

    @Test func rootHooksPublishMessagesAndCompletionWithoutAResumeRecord() throws {
        let fixture = Fixture()
        fixture.start()
        #expect(fixture.send("afterAgentResponse", generation: "turn-1", text: "The change is complete."))
        #expect(fixture.send("stop", generation: "turn-1", status: .ready))

        let feed = try fixture.feed()
        #expect(feed.provider == .cursor)
        #expect(feed.nativeSessionID == "root")
        #expect(fixture.store.nativeSessionBindingConfirmation(for: fixture.sessionID)?.nativeSessionID == "root")
        #expect(feed.observations.contains { observation in
            if case .transcript(.userMessage(let message)) = observation.payload {
                return message.text == "Explain this change"
            }
            return false
        })
        #expect(feed.observations.contains { observation in
            if case .transcript(.assistantMessage(let message)) = observation.payload {
                return message.text == "The change is complete."
            }
            return false
        })
        #expect(feed.observations.contains { $0.payload == .turnEnded(turnID: "turn-1", reason: .completed) })
    }

    @Test func duplicateNativeOwnerKeepsDesktopStatusWithoutRemoteAuthority() throws {
        let fixture = Fixture()
        fixture.start()
        let secondID = "second-cursor"
        fixture.store.startSession(
            sessionID: secondID, agent: .cursor, panelID: UUID(), windowID: UUID(),
            workspaceID: UUID(), cwd: "/repo", repoRoot: "/repo", at: fixture.date
        )
        #expect(fixture.store.handleCursorHookEvent(
            sessionID: secondID,
            event: .init(hookEventName: "sessionStart", conversationID: "root", generationID: nil,
                         status: .init(kind: .idle, summary: "Waiting")), at: fixture.date
        ))
        #expect(fixture.store.handleCursorHookEvent(
            sessionID: secondID,
            event: .init(hookEventName: "beforeSubmitPrompt", conversationID: "root",
                         generationID: "second-turn", status: nil, text: "Second panel"), at: fixture.date
        ))
        #expect(fixture.store.sessionRegistry.activeSession(sessionID: secondID)?.status?.kind == .working)
        #expect(fixture.store.nativeSessionBindingConfirmation(for: secondID) == nil)
        #expect(fixture.store.providerConversationFeed(managedSessionID: secondID) == nil)
    }

    @Test func unconfirmedPromptWaitsForRootAndNestedConversationCannotPublish() throws {
        let fixture = Fixture()
        fixture.send("beforeSubmitPrompt", generation: "turn-1", text: "Early prompt", status: .working)
        #expect(fixture.store.providerConversationFeed(managedSessionID: fixture.sessionID) == nil)
        fixture.send("sessionStart", status: .idle)
        let original = try fixture.feed()
        #expect(original.observations.contains { observation in
            if case .transcript(.userMessage(let message)) = observation.payload { return message.text == "Early prompt" }
            return false
        })
        #expect(fixture.send("sessionStart", conversation: "nested", status: .idle) == false)
        #expect(fixture.send("beforeSubmitPrompt", conversation: "nested", generation: "nested-turn", text: "Nested", status: .working) == false)
        #expect(fixture.send("afterAgentResponse", conversation: "nested", generation: "turn-1", text: "Nested response") == false)
        #expect(fixture.send("stop", conversation: "nested", generation: "turn-1", status: .ready) == false)
        #expect(try fixture.feed().observations == original.observations)
    }

    @Test func duplicatePromptAndStopDoNotDuplicateConversationFacts() throws {
        let fixture = Fixture()
        fixture.start()
        let started = try fixture.feed().observations
        fixture.send("beforeSubmitPrompt", generation: "turn-1", text: "Explain this change", status: .working)
        #expect(try fixture.feed().observations == started)
        fixture.send("stop", generation: "turn-1", status: .ready)
        let stopped = try fixture.feed().observations
        fixture.send("stop", generation: "turn-1", status: .ready)
        #expect(try fixture.feed().observations == stopped)
    }

    @Test func newRootAfterSessionEndReplacesPriorConversationFeed() throws {
        let fixture = Fixture()
        fixture.start()
        let original = try fixture.feed()
        fixture.send("sessionEnd")
        fixture.send("sessionStart", conversation: "new-root", status: .idle)
        fixture.send("beforeSubmitPrompt", conversation: "new-root", generation: "new-turn", text: "New prompt", status: .working)
        let replacement = try fixture.feed()
        #expect(replacement.nativeSessionID == "new-root")
        #expect(replacement.snapshotID != original.snapshotID)
        #expect(replacement.observations.contains { observation in
            if case .transcript(.userMessage(let message)) = observation.payload { return message.text == "New prompt" }
            return false
        })
        #expect(replacement.observations.contains { observation in
            if case .transcript(.userMessage(let message)) = observation.payload { return message.text == "Explain this change" }
            return false
        } == false)
        #expect(fixture.send("afterAgentResponse", generation: "turn-1", text: "Old answer") == false)
    }

    @Test func cloudHandoffDoesNotPublishLocalCompletionAuthority() throws {
        let fixture = Fixture()
        fixture.send("sessionStart", status: .idle)
        fixture.send("beforeSubmitPrompt", generation: "cloud-turn", text: "& investigate", cloud: true, status: .working)
        fixture.send("stop", generation: "cloud-turn", status: .ready)
        let observations = try fixture.feed().observations
        #expect(observations.contains { $0.payload == .turnEnded(turnID: "cloud-turn", reason: .aborted) })
        #expect(observations.contains { $0.payload == .turnEnded(turnID: "cloud-turn", reason: .completed) } == false)
    }

    @Test func delayedResponseAddsTextWithoutReopeningTheFinishedTurn() throws {
        let fixture = Fixture()
        fixture.start()
        fixture.send("stop", generation: "turn-1", status: .ready)
        let before = try fixture.feed().observations
        #expect(fixture.send("afterAgentResponse", generation: "turn-1", text: "Delayed answer"))
        let after = try fixture.feed().observations
        let responses = after.filter { observation in
            if case .transcript(.assistantMessage(let message)) = observation.payload { return message.text == "Delayed answer" }
            return false
        }
        #expect(responses.count == 1)
        #expect(responses.allSatisfy { $0.mayAuthorizeCurrentRuntime == false })
        #expect(after.filter { if case .turnEnded = $0.payload { return true }; return false }
            == before.filter { if case .turnEnded = $0.payload { return true }; return false })
    }
}
