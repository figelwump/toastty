import Foundation

public enum DiagnosticsSocketState: String, Codable, Equatable, Sendable {
    case healthy
    case refused
    case timeout
    case stale
    case noSocket = "no-socket"
}

public enum DiagnosticsSocketPathSource: String, Codable, Equatable, Sendable {
    case cliOption = "cli-option"
    case environment = "env"
    case discoveryRecord = "discovery-record"
    case latestLiveSocket = "latest-live-socket"
    case runtimeHome = "runtime-home"
    case legacy
}

public struct DiagnosticsSocketProbeResult: Codable, Equatable, Sendable {
    public var socketPath: String
    public var pathSource: DiagnosticsSocketPathSource
    public var state: DiagnosticsSocketState
    public var stat: DiagnosticsSocketStat
    public var instancePID: Int32?
    public var instancePIDAlive: Bool?
    public var connect: DiagnosticsSocketConnectResult
    public var ping: DiagnosticsSocketPingResult?
    public var currentSocketRecord: DiagnosticsSocketDiscoveryRecord?
    public var competingSockets: [DiagnosticsSocketCandidate]

    public init(
        socketPath: String,
        pathSource: DiagnosticsSocketPathSource,
        state: DiagnosticsSocketState,
        stat: DiagnosticsSocketStat,
        instancePID: Int32?,
        instancePIDAlive: Bool?,
        connect: DiagnosticsSocketConnectResult,
        ping: DiagnosticsSocketPingResult?,
        currentSocketRecord: DiagnosticsSocketDiscoveryRecord?,
        competingSockets: [DiagnosticsSocketCandidate]
    ) {
        self.socketPath = socketPath
        self.pathSource = pathSource
        self.state = state
        self.stat = stat
        self.instancePID = instancePID
        self.instancePIDAlive = instancePIDAlive
        self.connect = connect
        self.ping = ping
        self.currentSocketRecord = currentSocketRecord
        self.competingSockets = competingSockets
    }
}

public struct DiagnosticsSocketStat: Codable, Equatable, Sendable {
    public var exists: Bool
    public var isSocket: Bool
    public var mode: String?
    public var ownerUID: UInt32?
    public var groupID: UInt32?
    public var sizeBytes: UInt64?
    public var error: String?

    public init(
        exists: Bool,
        isSocket: Bool,
        mode: String?,
        ownerUID: UInt32?,
        groupID: UInt32?,
        sizeBytes: UInt64?,
        error: String?
    ) {
        self.exists = exists
        self.isSocket = isSocket
        self.mode = mode
        self.ownerUID = ownerUID
        self.groupID = groupID
        self.sizeBytes = sizeBytes
        self.error = error
    }
}

public struct DiagnosticsSocketConnectResult: Codable, Equatable, Sendable {
    public var status: String
    public var errnoCode: Int32?
    public var error: String?
    public var latencyMs: Int?

    public init(status: String, errnoCode: Int32?, error: String?, latencyMs: Int?) {
        self.status = status
        self.errnoCode = errnoCode
        self.error = error
        self.latencyMs = latencyMs
    }
}

public struct DiagnosticsSocketPingResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var latencyMs: Int?
    public var automationEnabled: Bool?
    public var appUptimeMs: Int?
    public var protocolVersion: String?
    public var error: String?

    public init(
        ok: Bool,
        latencyMs: Int?,
        automationEnabled: Bool?,
        appUptimeMs: Int?,
        protocolVersion: String?,
        error: String?
    ) {
        self.ok = ok
        self.latencyMs = latencyMs
        self.automationEnabled = automationEnabled
        self.appUptimeMs = appUptimeMs
        self.protocolVersion = protocolVersion
        self.error = error
    }
}

public struct DiagnosticsSocketDiscoveryRecord: Codable, Equatable, Sendable {
    public var socketPath: String
    public var processID: Int32
    public var processAlive: Bool
    public var readError: String?

    public init(socketPath: String, processID: Int32, processAlive: Bool, readError: String?) {
        self.socketPath = socketPath
        self.processID = processID
        self.processAlive = processAlive
        self.readError = readError
    }
}

public struct DiagnosticsSocketCandidate: Codable, Equatable, Sendable {
    public var path: String
    public var modifiedAtMs: Int64?
    public var pid: Int32?
    public var pidAlive: Bool?
    public var isCurrent: Bool

    public init(path: String, modifiedAtMs: Int64?, pid: Int32?, pidAlive: Bool?, isCurrent: Bool) {
        self.path = path
        self.modifiedAtMs = modifiedAtMs
        self.pid = pid
        self.pidAlive = pidAlive
        self.isCurrent = isCurrent
    }
}
