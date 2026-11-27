import CoreState
import Foundation
import RemoteProtocol

/// An agent conversation whose agent Toastty runs as its own process and
/// exchanges structured messages with, in place of a terminal that Toastty
/// types into and a transcript file that it reads.
///
/// The conversation keeps a terminal panel for its place in the workspace.
/// The agent does not run in that terminal: `RemoteAccessService` gives the
/// session each message, interrupt and answer that it would type there, and
/// takes the conversation's observations from the session.
@MainActor
protocol DirectConversationSession: AnyObject {
    var panelID: UUID { get }
    /// The agent's process runs and takes messages.
    var acceptsInput: Bool { get }

    /// Gives the agent one message. `delivered` means that the message is
    /// on its way to the process. The agent's own receipt, a user message
    /// with `clientRequestID`, says that the agent took it.
    func send(text: String, clientRequestID: String, deliveryMode: RemoteMessageDeliveryMode) -> TerminalInputDeliveryResult

    /// Asks the agent to stop its running turn. The turn ends when the
    /// agent says so.
    func interrupt() -> TerminalInputDeliveryResult

    /// Answers the request that waits under `responseID`. A request takes
    /// one answer: the first that fits.
    func answer(responseID: String, answers: [RemoteInteractionAnswer]) -> RemoteQuestionAnswerResult

    /// The turn state and the waiting requests now, for a projection that
    /// starts to follow the session after it began. Empty until the agent
    /// takes messages.
    func currentStateObservations() -> [ProviderTranscriptObservation]
}
