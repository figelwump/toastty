import Foundation

public struct DiagnosticsBundle: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generatedAtMs: Int64
    public var note: String?
    public var app: DiagnosticsAppSection
    public var logs: DiagnosticsLogsSection
    public var shell: DiagnosticsShellSection
    public var system: DiagnosticsSystemSection
    public var socket: DiagnosticsSocketProbeResult
    public var automation: DiagnosticsAutomationSection?
    public var probe: DiagnosticsProbeSection
    public var redaction: DiagnosticsRedactionSection?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generatedAtMs: Int64,
        note: String?,
        app: DiagnosticsAppSection,
        logs: DiagnosticsLogsSection,
        shell: DiagnosticsShellSection,
        system: DiagnosticsSystemSection,
        socket: DiagnosticsSocketProbeResult,
        automation: DiagnosticsAutomationSection? = nil,
        probe: DiagnosticsProbeSection,
        redaction: DiagnosticsRedactionSection? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAtMs = generatedAtMs
        self.note = note
        self.app = app
        self.logs = logs
        self.shell = shell
        self.system = system
        self.socket = socket
        self.automation = automation
        self.probe = probe
        self.redaction = redaction
    }
}

public struct RedactedDiagnosticsBundle: Encodable, Equatable, Sendable {
    public let bundle: DiagnosticsBundle

    init(bundle: DiagnosticsBundle) {
        self.bundle = bundle
    }

    public func encode(to encoder: Encoder) throws {
        try bundle.encode(to: encoder)
    }
}

public struct DiagnosticsAppSection: Codable, Equatable, Sendable {
    public var shortVersion: String?
    public var build: String?
    public var bundlePath: String?
    public var executablePath: String?
    public var runtimeHomePath: String?
    public var runtimeHomeStrategy: String
    public var runtimeLabel: String?
    public var isDevWorktree: Bool
    public var pid: Int32?
    public var pidAlive: Bool?
    public var runID: String?
    public var instanceFilePath: String?
    public var instanceStatus: DiagnosticsAvailability
    public var infoPlistStatus: DiagnosticsAvailability

    public init(
        shortVersion: String?,
        build: String?,
        bundlePath: String?,
        executablePath: String?,
        runtimeHomePath: String?,
        runtimeHomeStrategy: String,
        runtimeLabel: String?,
        isDevWorktree: Bool,
        pid: Int32?,
        pidAlive: Bool?,
        runID: String?,
        instanceFilePath: String?,
        instanceStatus: DiagnosticsAvailability,
        infoPlistStatus: DiagnosticsAvailability
    ) {
        self.shortVersion = shortVersion
        self.build = build
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.runtimeHomePath = runtimeHomePath
        self.runtimeHomeStrategy = runtimeHomeStrategy
        self.runtimeLabel = runtimeLabel
        self.isDevWorktree = isDevWorktree
        self.pid = pid
        self.pidAlive = pidAlive
        self.runID = runID
        self.instanceFilePath = instanceFilePath
        self.instanceStatus = instanceStatus
        self.infoPlistStatus = infoPlistStatus
    }
}

public struct DiagnosticsLogsSection: Codable, Equatable, Sendable {
    public var current: DiagnosticsLogFile
    public var previous: DiagnosticsLogFile
    public var configSummary: [String: String]

    public init(
        current: DiagnosticsLogFile,
        previous: DiagnosticsLogFile,
        configSummary: [String: String]
    ) {
        self.current = current
        self.previous = previous
        self.configSummary = configSummary
    }
}

public struct DiagnosticsLogFile: Codable, Equatable, Sendable {
    public var path: String
    public var exists: Bool
    public var sizeBytes: UInt64?
    public var modifiedAtMs: Int64?
    public var content: String?
    public var readError: String?
    public var truncated: Bool

    public init(
        path: String,
        exists: Bool,
        sizeBytes: UInt64?,
        modifiedAtMs: Int64?,
        content: String?,
        readError: String?,
        truncated: Bool = false
    ) {
        self.path = path
        self.exists = exists
        self.sizeBytes = sizeBytes
        self.modifiedAtMs = modifiedAtMs
        self.content = content
        self.readError = readError
        self.truncated = truncated
    }
}

public struct DiagnosticsShellSection: Codable, Equatable, Sendable {
    public var detectedShells: [DiagnosticsShellInitFile]
    public var shimDirectory: DiagnosticsDirectoryListing
    public var environment: [DiagnosticsEnvironmentEntry]
    public var otherEnvironmentNames: [String]

    public init(
        detectedShells: [DiagnosticsShellInitFile],
        shimDirectory: DiagnosticsDirectoryListing,
        environment: [DiagnosticsEnvironmentEntry],
        otherEnvironmentNames: [String]
    ) {
        self.detectedShells = detectedShells
        self.shimDirectory = shimDirectory
        self.environment = environment
        self.otherEnvironmentNames = otherEnvironmentNames
    }
}

public struct DiagnosticsShellInitFile: Codable, Equatable, Sendable {
    public var name: String
    public var rcPath: String
    public var exists: Bool
    public var sourcingMarkerPresent: Bool
    public var readError: String?

    public init(
        name: String,
        rcPath: String,
        exists: Bool,
        sourcingMarkerPresent: Bool,
        readError: String?
    ) {
        self.name = name
        self.rcPath = rcPath
        self.exists = exists
        self.sourcingMarkerPresent = sourcingMarkerPresent
        self.readError = readError
    }
}

public struct DiagnosticsDirectoryListing: Codable, Equatable, Sendable {
    public var path: String
    public var exists: Bool
    public var entries: [DiagnosticsDirectoryEntry]
    public var readError: String?

    public init(
        path: String,
        exists: Bool,
        entries: [DiagnosticsDirectoryEntry],
        readError: String?
    ) {
        self.path = path
        self.exists = exists
        self.entries = entries
        self.readError = readError
    }
}

public struct DiagnosticsDirectoryEntry: Codable, Equatable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var isExecutable: Bool
    public var sizeBytes: UInt64?

    public init(name: String, isDirectory: Bool, isExecutable: Bool, sizeBytes: UInt64?) {
        self.name = name
        self.isDirectory = isDirectory
        self.isExecutable = isExecutable
        self.sizeBytes = sizeBytes
    }
}

public struct DiagnosticsEnvironmentEntry: Codable, Equatable, Sendable {
    public var name: String
    public var value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

public struct DiagnosticsSystemSection: Codable, Equatable, Sendable {
    public var macosVersion: String
    public var hardwareModel: String?
    public var arch: String

    public init(macosVersion: String, hardwareModel: String?, arch: String) {
        self.macosVersion = macosVersion
        self.hardwareModel = hardwareModel
        self.arch = arch
    }
}

public struct DiagnosticsProbeSection: Codable, Equatable, Sendable {
    public var shellProbePath: String?
    public var rawShellProbe: String?
    public var readError: String?

    public init(shellProbePath: String?, rawShellProbe: String?, readError: String?) {
        self.shellProbePath = shellProbePath
        self.rawShellProbe = rawShellProbe
        self.readError = readError
    }
}

public struct DiagnosticsAutomationSection: Codable, Equatable, Sendable {
    public var status: DiagnosticsAvailability
    public var recentRequests: [DiagnosticsAutomationRequestEntry]

    public init(
        status: DiagnosticsAvailability,
        recentRequests: [DiagnosticsAutomationRequestEntry]
    ) {
        self.status = status
        self.recentRequests = recentRequests
    }

    public static func unavailable(_ detail: String) -> DiagnosticsAutomationSection {
        DiagnosticsAutomationSection(
            status: .unavailable(detail),
            recentRequests: []
        )
    }
}

public struct DiagnosticsAutomationRequestEntry: Codable, Equatable, Sendable {
    public var timestampMs: Int64
    public var kind: String
    public var requestID: String?
    public var command: String?
    public var eventType: String?
    public var callerSessionID: String?
    public var callerAgent: String?
    public var sessionID: String?
    public var panelID: String?
    public var actionID: String?
    public var queryID: String?
    public var argumentKeys: [String]
    public var selectors: [String: AutomationJSONValue]
    public var flags: [String: AutomationJSONValue]
    public var ok: Bool
    public var durationMs: Int
    public var errorCode: String?

    public init(
        timestampMs: Int64,
        kind: String,
        requestID: String?,
        command: String?,
        eventType: String?,
        callerSessionID: String?,
        callerAgent: String?,
        sessionID: String?,
        panelID: String?,
        actionID: String?,
        queryID: String?,
        argumentKeys: [String],
        selectors: [String: AutomationJSONValue],
        flags: [String: AutomationJSONValue],
        ok: Bool,
        durationMs: Int,
        errorCode: String?
    ) {
        self.timestampMs = timestampMs
        self.kind = kind
        self.requestID = requestID
        self.command = command
        self.eventType = eventType
        self.callerSessionID = callerSessionID
        self.callerAgent = callerAgent
        self.sessionID = sessionID
        self.panelID = panelID
        self.actionID = actionID
        self.queryID = queryID
        self.argumentKeys = argumentKeys
        self.selectors = selectors
        self.flags = flags
        self.ok = ok
        self.durationMs = durationMs
        self.errorCode = errorCode
    }
}

public struct DiagnosticsRedactionSection: Codable, Equatable, Sendable {
    public var rulesVersion: Int
    public var redactedKeyCount: Int

    public init(rulesVersion: Int, redactedKeyCount: Int) {
        self.rulesVersion = rulesVersion
        self.redactedKeyCount = redactedKeyCount
    }
}

public struct DiagnosticsAvailability: Codable, Equatable, Sendable {
    public var status: String
    public var detail: String?

    public init(status: String, detail: String? = nil) {
        self.status = status
        self.detail = detail
    }

    public static let available = DiagnosticsAvailability(status: "available")

    public static func unavailable(_ detail: String) -> DiagnosticsAvailability {
        DiagnosticsAvailability(status: "unavailable", detail: detail)
    }
}
