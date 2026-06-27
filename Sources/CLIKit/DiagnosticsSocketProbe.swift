import CoreState
import Darwin
import Foundation

struct DiagnosticsSocketProbe {
    typealias ConnectProbe = (String, TimeInterval) -> DiagnosticsSocketConnectResult
    typealias PingProbe = (String, TimeInterval) -> DiagnosticsSocketPingResult

    var timeoutInterval: TimeInterval = 2
    var connectProbe: ConnectProbe = Self.defaultConnectProbe
    var pingProbe: PingProbe = Self.defaultPingProbe
    var fileManager: FileManager = .default

    func probe(
        environment: [String: String],
        homeDirectoryPath: String = NSHomeDirectory(),
        socketPathOverride: String? = nil,
        pathSourceOverride: DiagnosticsSocketPathSource? = nil
    ) -> DiagnosticsSocketProbeResult {
        let socketPath = socketPathOverride ?? AutomationConfig.resolveSocketPath(environment: environment)
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
        let discoveryRecord = readDiscoveryRecord(environment: environment)
        let candidates = socketCandidates(environment: environment, currentPath: socketPath)
        let pathSource = resolvedPathSource(
            socketPath: socketPath,
            environment: environment,
            runtimePaths: runtimePaths,
            discoveryRecord: discoveryRecord,
            candidates: candidates,
            override: pathSourceOverride
        )
        let stat = socketStat(path: socketPath)
        let instancePID = readInstancePID(runtimePaths: runtimePaths)
        let instancePIDAlive = instancePID.map(Self.processIsAlive)

        let connect: DiagnosticsSocketConnectResult
        let ping: DiagnosticsSocketPingResult?
        if stat.exists, stat.isSocket {
            connect = connectProbe(socketPath, timeoutInterval)
            if connect.status == "connected" {
                ping = pingProbe(socketPath, timeoutInterval)
            } else {
                ping = nil
            }
        } else {
            connect = DiagnosticsSocketConnectResult(
                status: stat.exists ? "not-socket" : "not-found",
                errnoCode: nil,
                error: stat.error,
                latencyMs: nil
            )
            ping = nil
        }

        return DiagnosticsSocketProbeResult(
            socketPath: socketPath,
            pathSource: pathSource,
            state: state(stat: stat, instancePIDAlive: instancePIDAlive, connect: connect, ping: ping),
            stat: stat,
            instancePID: instancePID,
            instancePIDAlive: instancePIDAlive,
            connect: connect,
            ping: ping,
            currentSocketRecord: discoveryRecord,
            competingSockets: candidates
        )
    }

    private func state(
        stat: DiagnosticsSocketStat,
        instancePIDAlive: Bool?,
        connect: DiagnosticsSocketConnectResult,
        ping: DiagnosticsSocketPingResult?
    ) -> DiagnosticsSocketState {
        guard stat.exists else {
            return .noSocket
        }
        guard stat.isSocket else {
            return .stale
        }
        if instancePIDAlive == false {
            return .stale
        }

        switch connect.status {
        case "connected":
            return ping?.ok == true ? .healthy : .stale
        case "refused":
            return .refused
        case "timeout":
            return .timeout
        default:
            return .stale
        }
    }

    private func resolvedPathSource(
        socketPath: String,
        environment: [String: String],
        runtimePaths: ToasttyRuntimePaths,
        discoveryRecord: DiagnosticsSocketDiscoveryRecord?,
        candidates: [DiagnosticsSocketCandidate],
        override: DiagnosticsSocketPathSource?
    ) -> DiagnosticsSocketPathSource {
        if let override {
            return override
        }

        if let explicit = environment[ToasttyLaunchContextEnvironment.socketPathKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           explicit.isEmpty == false {
            return .environment
        }

        if discoveryRecord?.socketPath == socketPath {
            return .discoveryRecord
        }

        if runtimePaths.automationSocketFileURL?.path == socketPath {
            return .runtimeHome
        }

        if candidates.contains(where: { $0.path == socketPath }) {
            return .latestLiveSocket
        }

        return .legacy
    }

    private func socketStat(path: String) -> DiagnosticsSocketStat {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT {
                return DiagnosticsSocketStat(
                    exists: false,
                    isSocket: false,
                    mode: nil,
                    ownerUID: nil,
                    groupID: nil,
                    sizeBytes: nil,
                    error: nil
                )
            }

            return DiagnosticsSocketStat(
                exists: false,
                isSocket: false,
                mode: nil,
                ownerUID: nil,
                groupID: nil,
                sizeBytes: nil,
                error: String(cString: strerror(errno))
            )
        }

        return DiagnosticsSocketStat(
            exists: true,
            isSocket: (info.st_mode & S_IFMT) == S_IFSOCK,
            mode: String(format: "%04o", info.st_mode & 0o7777),
            ownerUID: info.st_uid,
            groupID: info.st_gid,
            sizeBytes: UInt64(info.st_size),
            error: nil
        )
    }

    private func readInstancePID(runtimePaths: ToasttyRuntimePaths) -> Int32? {
        guard let instanceFileURL = runtimePaths.instanceFileURL,
              let data = try? Data(contentsOf: instanceFileURL),
              let manifest = try? JSONDecoder().decode(RuntimeInstanceManifest.self, from: data) else {
            return nil
        }
        return manifest.pid
    }

    private func readDiscoveryRecord(environment: [String: String]) -> DiagnosticsSocketDiscoveryRecord? {
        let recordURL = socketDirectoryURL(environment: environment)
            .appendingPathComponent("current-socket.json", isDirectory: false)
        guard fileManager.fileExists(atPath: recordURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: recordURL)
            let record = try JSONDecoder().decode(SocketDiscoveryRecord.self, from: data)
            return DiagnosticsSocketDiscoveryRecord(
                socketPath: record.socketPath,
                processID: record.processID,
                processAlive: Self.processIsAlive(record.processID),
                readError: nil
            )
        } catch {
            return DiagnosticsSocketDiscoveryRecord(
                socketPath: "",
                processID: 0,
                processAlive: false,
                readError: error.localizedDescription
            )
        }
    }

    private func socketCandidates(
        environment: [String: String],
        currentPath: String
    ) -> [DiagnosticsSocketCandidate] {
        let directoryURL = socketDirectoryURL(environment: environment)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { url in
                let name = url.lastPathComponent
                return name == "events-v1.sock" || (name.hasPrefix("events-v1-") && name.hasSuffix(".sock"))
            }
            .map { url in
                let pid = pidFromSocketFilename(url.lastPathComponent)
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                return DiagnosticsSocketCandidate(
                    path: url.path,
                    modifiedAtMs: values?.contentModificationDate.map(millisecondsSinceEpoch),
                    pid: pid,
                    pidAlive: pid.map(Self.processIsAlive),
                    isCurrent: url.path == currentPath
                )
            }
            .sorted { lhs, rhs in
                if lhs.path == rhs.path {
                    return false
                }
                return lhs.path < rhs.path
            }
    }

    private func socketDirectoryURL(environment: [String: String]) -> URL {
        let tempDirectory = environment["TMPDIR"] ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: tempDirectory, isDirectory: true)
            .appendingPathComponent("toastty-\(getuid())", isDirectory: true)
    }

    private func pidFromSocketFilename(_ filename: String) -> Int32? {
        guard filename.hasPrefix("events-v1-"), filename.hasSuffix(".sock") else {
            return nil
        }
        let value = filename
            .dropFirst("events-v1-".count)
            .dropLast(".sock".count)
        return Int32(value)
    }

    static func defaultPingProbe(
        socketPath: String,
        timeoutInterval: TimeInterval
    ) -> DiagnosticsSocketPingResult {
        let started = Date()
        do {
            let request = AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "automation.ping"
            )
            let response = try ToasttySocketClient(
                socketPath: socketPath,
                timeoutInterval: timeoutInterval
            ).send(request)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            guard response.ok else {
                return DiagnosticsSocketPingResult(
                    ok: false,
                    latencyMs: latency,
                    automationEnabled: nil,
                    appUptimeMs: nil,
                    protocolVersion: response.protocolVersion,
                    error: response.error.map { "\($0.code): \($0.message)" } ?? "request failed"
                )
            }
            return DiagnosticsSocketPingResult(
                ok: true,
                latencyMs: latency,
                automationEnabled: response.result?.bool("automationEnabled"),
                appUptimeMs: response.result?.int("appUptimeMs"),
                protocolVersion: response.result?.string("protocolVersion") ?? response.protocolVersion,
                error: nil
            )
        } catch {
            return DiagnosticsSocketPingResult(
                ok: false,
                latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                automationEnabled: nil,
                appUptimeMs: nil,
                protocolVersion: nil,
                error: error.localizedDescription
            )
        }
    }

    static func defaultConnectProbe(
        socketPath: String,
        timeoutInterval: TimeInterval
    ) -> DiagnosticsSocketConnectResult {
        let started = Date()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return DiagnosticsSocketConnectResult(
                status: "error",
                errnoCode: errno,
                error: String(cString: strerror(errno)),
                latencyMs: nil
            )
        }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            return DiagnosticsSocketConnectResult(
                status: "error",
                errnoCode: ENAMETOOLONG,
                error: "socket path too long",
                latencyMs: nil
            )
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                if let destination = buffer.baseAddress, let source = source.baseAddress {
                    memcpy(destination, source, pathBytes.count)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult == 0 {
            return DiagnosticsSocketConnectResult(
                status: "connected",
                errnoCode: nil,
                error: nil,
                latencyMs: Int(Date().timeIntervalSince(started) * 1000)
            )
        }

        let connectErrno = errno
        guard connectErrno == EINPROGRESS || connectErrno == EALREADY else {
            return connectFailure(errnoCode: connectErrno, started: started)
        }

        var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let timeoutMs = Int32(max(1, Int((timeoutInterval * 1000).rounded())))
        let pollResult = poll(&pollDescriptor, 1, timeoutMs)
        if pollResult == 0 {
            return DiagnosticsSocketConnectResult(
                status: "timeout",
                errnoCode: ETIMEDOUT,
                error: "connect timed out",
                latencyMs: Int(Date().timeIntervalSince(started) * 1000)
            )
        }
        if pollResult < 0 {
            return connectFailure(errnoCode: errno, started: started)
        }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        let result = withUnsafeMutablePointer(to: &socketError) { pointer in
            getsockopt(fd, SOL_SOCKET, SO_ERROR, pointer, &socketErrorLength)
        }
        guard result == 0 else {
            return connectFailure(errnoCode: errno, started: started)
        }
        guard socketError == 0 else {
            return connectFailure(errnoCode: socketError, started: started)
        }

        return DiagnosticsSocketConnectResult(
            status: "connected",
            errnoCode: nil,
            error: nil,
            latencyMs: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    private static func connectFailure(
        errnoCode: Int32,
        started: Date
    ) -> DiagnosticsSocketConnectResult {
        let status: String
        switch errnoCode {
        case ECONNREFUSED:
            status = "refused"
        case ETIMEDOUT:
            status = "timeout"
        case ENOENT:
            status = "not-found"
        default:
            status = "error"
        }
        return DiagnosticsSocketConnectResult(
            status: status,
            errnoCode: errnoCode,
            error: String(cString: strerror(errnoCode)),
            latencyMs: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func millisecondsSinceEpoch(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private struct RuntimeInstanceManifest: Decodable {
        let pid: Int32?
    }

    private struct SocketDiscoveryRecord: Decodable {
        let socketPath: String
        let processID: Int32
    }
}
