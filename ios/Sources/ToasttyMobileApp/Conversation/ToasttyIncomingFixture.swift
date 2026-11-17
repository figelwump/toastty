#if DEBUG
import Foundation
import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain
import UIKit

/// `TOASTTY_MOBILE_FIXTURE_INCOMING=1`: what the Mac sends to the
/// coordinator's chat, or to the task fixture's session, while the user
/// types there, one step per button, and a log of the keyboard. The agent
/// works when the chat opens.
struct ToasttyIncomingFixture: Equatable {
    /// The agent's turn, as the composer's gate sees it.
    enum Turn: Equatable {
        /// Send steers into the turn or queues for the next prompt.
        case working
        /// The turn ended and the prompt is still closed. The Mac holds a
        /// Claude prompt closed for 500 ms after a turn completes
        /// (`claudePromptStabilizationDelay`); the phone's gate is closed
        /// meanwhile.
        case closing
        /// The prompt opened.
        case open
    }

    enum Step: String, CaseIterable {
        /// A response arrives while the agent still works.
        case response
        /// The session's status changes, with no new text.
        case status
        /// The last response arrives and the turn ends.
        case turnEnd = "turn-end"
        /// The Mac opens the prompt.
        case promptOpens = "prompt-opens"
    }

    private(set) var turn = Turn.working
    private(set) var responses = 0
    /// Keyboard notifications and steps, in seconds from the first entry.
    private(set) var log: [String] = []
    private(set) var keyboardHides = 0
    private var start: Date?

    var availableSteps: [Step] {
        switch turn {
        case .working: [.response, .status, .turnEnd]
        case .closing: [.promptOpens]
        case .open: []
        }
    }

    mutating func apply(_ step: Step) {
        switch step {
        case .response:
            responses += 1
        case .status:
            break
        case .turnEnd:
            responses += 1
            turn = .closing
        case .promptOpens:
            turn = .open
        }
        record(step.rawValue)
    }

    mutating func keyboardWillShow() {
        record("show")
    }

    mutating func keyboardWillHide() {
        keyboardHides += 1
        record("hide")
    }

    private mutating func record(_ entry: String) {
        let now = Date()
        let start = start ?? now
        self.start = start
        log.append("\(entry)@\(String(format: "%.2f", now.timeIntervalSince(start)))")
    }

    /// The gate while the Mac holds the prompt closed after the turn: the
    /// turn's epoch is gone and the prompt is not open yet, so the phone
    /// has no stamp, as `ConversationRuntime` reports it.
    static let closingComposer = ToasttyComposerPresentation.make(
        agentDisplayName: "Claude",
        authority: ConversationComposerAuthority(
            inputAvailability: .unavailable(reason: .known(.unknownProviderState)),
            gateFailure: .inputUnavailable
        )
    )
}

/// The step buttons and the keyboard log over the chat. A tap on a button
/// does not move the keyboard focus.
struct ToasttyIncomingFixtureControls: View {
    let fixture: ToasttyIncomingFixture
    let apply: (ToasttyIncomingFixture.Step) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(fixture.availableSteps, id: \.self) { step in
                Button(step.rawValue) { apply(step) }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(ToasttyDesignTokens.inkOnAmber)
                    .background(ToasttyDesignTokens.amber, in: Capsule())
                    .accessibilityIdentifier("toastty-mobile-fixture-incoming-\(step.rawValue)")
            }
            Text("hides \(fixture.keyboardHides)")
                .font(.caption2.monospaced())
                .accessibilityLabel(fixture.log.joined(separator: " "))
                .accessibilityValue("\(fixture.keyboardHides)")
                .accessibilityIdentifier("toastty-mobile-fixture-keyboard-log")
        }
        .padding(.top, 56)
        .padding(.trailing, 8)
    }
}

extension View {
    /// Records the keyboard's show and hide in the incoming fixture's log.
    func toasttyIncomingKeyboardLog(_ fixture: Binding<ToasttyIncomingFixture?>) -> some View {
        onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            fixture.wrappedValue?.keyboardWillShow()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            fixture.wrappedValue?.keyboardWillHide()
        }
    }
}
#endif
