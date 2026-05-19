import Foundation

public struct CodexHookEvent: Equatable, Sendable {
    public var hookEventName: String
    public var source: String?
    public var threadID: String?
    public var turnID: String?
    public var promptFingerprint: String?
    public var status: SessionStatus?
    public var nativeSessionID: String?
    public var sessionFilePath: String?
    public var cwd: String?

    public init(
        hookEventName: String,
        source: String? = nil,
        threadID: String?,
        turnID: String?,
        promptFingerprint: String?,
        status: SessionStatus?,
        nativeSessionID: String?,
        sessionFilePath: String?,
        cwd: String?
    ) {
        self.hookEventName = hookEventName
        self.source = source
        self.threadID = threadID
        self.turnID = turnID
        self.promptFingerprint = promptFingerprint
        self.status = status
        self.nativeSessionID = nativeSessionID
        self.sessionFilePath = sessionFilePath
        self.cwd = cwd
    }
}
