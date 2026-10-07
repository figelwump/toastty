import Foundation

/// A bounded, normalized Cursor hook observation forwarded by the Toastty CLI.
///
/// Cursor hooks run in separate processes, so root conversation and turn
/// correlation must be reconciled by the app rather than by the CLI parser.
public struct CursorHookEvent: Equatable, Sendable {
    /// Remote start and plain-text send requests can contain up to 64 KiB.
    public static let maximumPromptTextUTF8Count = 64 * 1024
    public static let maximumResponseTextUTF8Count = 48 * 1024
    public static let maximumModelIdentifierUTF8Count = 512
    public static let textTruncationSuffix = "\n\n[Text truncated]"

    public var hookEventName: String
    public var conversationID: String?
    public var generationID: String?
    public var cloudHandoff: Bool
    public var status: SessionStatus?
    public var text: String?
    public var modelIdentifier: String?

    public init(
        hookEventName: String,
        conversationID: String?,
        generationID: String?,
        cloudHandoff: Bool = false,
        status: SessionStatus?,
        text: String? = nil,
        modelIdentifier: String? = nil
    ) {
        self.hookEventName = hookEventName
        self.conversationID = conversationID
        self.generationID = generationID
        self.cloudHandoff = cloudHandoff
        self.status = status
        self.text = text
        self.modelIdentifier = modelIdentifier
    }
}
