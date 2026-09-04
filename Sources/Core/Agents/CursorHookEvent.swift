import Foundation

/// A bounded, normalized Cursor hook observation forwarded by the Toastty CLI.
///
/// Cursor hooks run in separate processes, so root conversation and turn
/// correlation must be reconciled by the app rather than by the CLI parser.
public struct CursorHookEvent: Equatable, Sendable {
    public var hookEventName: String
    public var conversationID: String?
    public var generationID: String?
    public var cloudHandoff: Bool
    public var status: SessionStatus?

    public init(
        hookEventName: String,
        conversationID: String?,
        generationID: String?,
        cloudHandoff: Bool = false,
        status: SessionStatus?
    ) {
        self.hookEventName = hookEventName
        self.conversationID = conversationID
        self.generationID = generationID
        self.cloudHandoff = cloudHandoff
        self.status = status
    }
}
