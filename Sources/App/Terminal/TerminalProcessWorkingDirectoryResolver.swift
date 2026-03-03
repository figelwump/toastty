#if TOASTTY_HAS_GHOSTTY_KIT
import CoreState
import Foundation
import Darwin

final class TerminalProcessWorkingDirectoryResolver {
    private struct ProcessStartSignature: Equatable {
        let seconds: UInt64
        let microseconds: UInt64
    }

    private struct CachedProcessEntry {
        let pid: pid_t
        let commandName: String
        let startSignature: ProcessStartSignature
    }

    private let currentProcessID: pid_t
    private let currentUserID: uid_t
    private let argmax: Int
    private let panelIDEnvironmentKey = "TOASTTY_PANEL_ID"

    private var cachedProcessByPanelID: [UUID: CachedProcessEntry] = [:]
    private var resolutionMissCountByPanelID: [UUID: Int] = [:]

    private let shellCommandNames: Set<String> = [
        "bash",
        "fish",
        "ksh",
        "nu",
        "sh",
        "tcsh",
        "tmux",
        "xonsh",
        "zsh",
    ]

    init() {
        currentProcessID = getpid()
        currentUserID = getuid()
        argmax = Self.systemArgmaxOrDefault()
    }

    func resolveWorkingDirectory(for panelID: UUID) -> String? {
        if let cachedEntry = cachedProcessByPanelID[panelID] {
            if let cwd = resolveWorkingDirectoryFromCache(panelID: panelID, entry: cachedEntry) {
                clearMisses(for: panelID)
                return cwd
            }

            cachedProcessByPanelID.removeValue(forKey: panelID)
            ToasttyLog.debug(
                "Invalidated cached process cwd mapping for terminal panel",
                category: .terminal,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "pid": String(cachedEntry.pid),
                    "command": cachedEntry.commandName,
                ]
            )
        }

        guard let discoveredEntry = discoverProcess(for: panelID) else {
            recordMiss(for: panelID, reason: "no_matching_process")
            return nil
        }

        guard let cwd = processWorkingDirectory(pid: discoveredEntry.pid) else {
            recordMiss(for: panelID, reason: "cwd_read_failed_after_discovery")
            return nil
        }

        cachedProcessByPanelID[panelID] = discoveredEntry
        ToasttyLog.debug(
            "Resolved terminal cwd process for panel",
            category: .terminal,
            metadata: [
                "panel_id": panelID.uuidString,
                "pid": String(discoveredEntry.pid),
                "command": discoveredEntry.commandName,
                "cwd_sample": String(cwd.prefix(120)),
            ]
        )
        clearMisses(for: panelID)
        return cwd
    }

    func invalidate(panelID: UUID) {
        cachedProcessByPanelID.removeValue(forKey: panelID)
        resolutionMissCountByPanelID.removeValue(forKey: panelID)
    }

    private func resolveWorkingDirectoryFromCache(panelID: UUID, entry: CachedProcessEntry) -> String? {
        guard let currentSignature = processStartSignature(pid: entry.pid),
              currentSignature == entry.startSignature else {
            return nil
        }

        guard let cwd = processWorkingDirectory(pid: entry.pid) else {
            recordMiss(for: panelID, reason: "cached_pid_cwd_read_failed")
            return nil
        }

        return cwd
    }

    private func discoverProcess(for panelID: UUID) -> CachedProcessEntry? {
        let panelIDValue = panelID.uuidString
        var bestShellEntry: CachedProcessEntry?
        var bestFallbackEntry: CachedProcessEntry?

        for pid in allProcessIDs() {
            guard pid > 0, pid != currentProcessID else { continue }
            guard let processInfo = processInfo(pid: pid) else { continue }
            guard processInfo.uid == currentUserID else { continue }
            guard processEnvironmentValue(pid: pid, key: panelIDEnvironmentKey) == panelIDValue else { continue }

            let candidate = CachedProcessEntry(
                pid: pid,
                commandName: processInfo.commandName,
                startSignature: processInfo.startSignature
            )

            if shellCommandNames.contains(processInfo.commandName.lowercased()) {
                if let currentBestShellEntry = bestShellEntry {
                    if candidate.pid < currentBestShellEntry.pid {
                        bestShellEntry = candidate
                    }
                } else {
                    bestShellEntry = candidate
                }
            } else if let currentBestFallbackEntry = bestFallbackEntry {
                if candidate.pid < currentBestFallbackEntry.pid {
                    bestFallbackEntry = candidate
                }
            } else {
                bestFallbackEntry = candidate
            }
        }

        return bestShellEntry ?? bestFallbackEntry
    }

    private struct ProcessInfo {
        let uid: uid_t
        let commandName: String
        let startSignature: ProcessStartSignature
    }

    private func processInfo(pid: pid_t) -> ProcessInfo? {
        var info = proc_bsdinfo()
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                infoPointer,
                Int32(MemoryLayout<proc_bsdinfo>.stride)
            )
        }

        guard result == Int32(MemoryLayout<proc_bsdinfo>.stride) else {
            return nil
        }

        let commandName = processCommandName(from: &info)
        let startSignature = ProcessStartSignature(
            seconds: UInt64(info.pbi_start_tvsec),
            microseconds: UInt64(info.pbi_start_tvusec)
        )

        return ProcessInfo(
            uid: info.pbi_uid,
            commandName: commandName,
            startSignature: startSignature
        )
    }

    private func processStartSignature(pid: pid_t) -> ProcessStartSignature? {
        guard let info = processInfo(pid: pid) else { return nil }
        return info.startSignature
    }

    private func processCommandName(from info: inout proc_bsdinfo) -> String {
        let primaryName = Self.stringFromCCharTuple(&info.pbi_name)
        if primaryName.isEmpty == false {
            return primaryName
        }

        let command = Self.stringFromCCharTuple(&info.pbi_comm)
        if command.isEmpty == false {
            return command
        }

        return "unknown"
    }

    private func processWorkingDirectory(pid: pid_t) -> String? {
        var vnodePathInfo = proc_vnodepathinfo()
        let result = withUnsafeMutablePointer(to: &vnodePathInfo) { infoPointer in
            proc_pidinfo(
                pid,
                PROC_PIDVNODEPATHINFO,
                0,
                infoPointer,
                Int32(MemoryLayout<proc_vnodepathinfo>.stride)
            )
        }

        guard result == Int32(MemoryLayout<proc_vnodepathinfo>.stride) else {
            return nil
        }

        let workingDirectory = withUnsafePointer(to: &vnodePathInfo.pvi_cdir.vip_path) { pathPointer -> String? in
            pathPointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cStringPointer in
                guard cStringPointer.pointee != 0 else { return nil }
                return String(cString: cStringPointer)
            }
        }

        guard let workingDirectory else { return nil }
        let normalized = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }
        return normalized
    }

    private func processEnvironmentValue(pid: pid_t, key: String) -> String? {
        guard argmax > 0 else { return nil }

        var mib = [
            Int32(CTL_KERN),
            Int32(KERN_PROCARGS2),
            pid,
        ]
        var byteCount = argmax
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: argmax,
            alignment: MemoryLayout<Int32>.alignment
        )
        defer {
            buffer.deallocate()
        }

        let sysctlResult = sysctl(&mib, u_int(mib.count), buffer, &byteCount, nil, 0)
        guard sysctlResult == 0, byteCount > MemoryLayout<Int32>.size else {
            return nil
        }

        let argumentCount = Int(buffer.load(as: Int32.self))
        guard argumentCount >= 0 else {
            return nil
        }

        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        var index = MemoryLayout<Int32>.size

        func skipNullBytes() {
            while index < byteCount, bytes[index] == 0 {
                index += 1
            }
        }

        func skipCString() {
            while index < byteCount, bytes[index] != 0 {
                index += 1
            }
        }

        // argv layout: argc, executable path, args..., env...
        skipCString()
        skipNullBytes()

        if argumentCount > 0 {
            for _ in 0..<argumentCount {
                skipCString()
                skipNullBytes()
                if index >= byteCount {
                    return nil
                }
            }
        }

        while index < byteCount {
            skipNullBytes()
            guard index < byteCount else { break }

            let start = index
            skipCString()
            guard index > start else { continue }

            let length = index - start
            let entry = UnsafeBufferPointer(start: bytes.advanced(by: start), count: length)
            let value = String(decoding: entry, as: UTF8.self)

            guard value.hasPrefix(key) else { continue }
            guard value.count > key.count, value[value.index(value.startIndex, offsetBy: key.count)] == "=" else {
                continue
            }

            let valueStart = value.index(value.startIndex, offsetBy: key.count + 1)
            return String(value[valueStart...])
        }

        return nil
    }

    private func allProcessIDs() -> [pid_t] {
        var capacity = 4096
        let pidSize = MemoryLayout<pid_t>.stride

        while capacity <= 131_072 {
            var processIDs = Array(repeating: pid_t(0), count: capacity)
            let returnedBytes = processIDs.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return proc_listpids(
                    UInt32(PROC_ALL_PIDS),
                    0,
                    UnsafeMutableRawPointer(baseAddress),
                    Int32(buffer.count * pidSize)
                )
            }

            guard returnedBytes > 0 else {
                return []
            }

            let processCount = Int(returnedBytes) / pidSize
            if processCount < capacity {
                return processIDs[0..<processCount].filter { $0 > 0 }
            }

            capacity *= 2
        }

        return []
    }

    private func recordMiss(for panelID: UUID, reason: String) {
        let missCount = (resolutionMissCountByPanelID[panelID] ?? 0) + 1
        resolutionMissCountByPanelID[panelID] = missCount

        guard missCount <= 2 || missCount.isMultiple(of: 30) else {
            return
        }

        ToasttyLog.debug(
            "Terminal process cwd resolution miss",
            category: .terminal,
            metadata: [
                "panel_id": panelID.uuidString,
                "reason": reason,
                "miss_count": String(missCount),
            ]
        )
    }

    private func clearMisses(for panelID: UUID) {
        guard let previousMissCount = resolutionMissCountByPanelID.removeValue(forKey: panelID),
              previousMissCount > 0 else {
            return
        }

        ToasttyLog.debug(
            "Terminal process cwd resolution recovered",
            category: .terminal,
            metadata: [
                "panel_id": panelID.uuidString,
                "previous_miss_count": String(previousMissCount),
            ]
        )
    }

    private static func systemArgmaxOrDefault() -> Int {
        var mib = [Int32(CTL_KERN), Int32(KERN_ARGMAX)]
        var argmaxValue: Int32 = 0
        var valueSize = MemoryLayout<Int32>.size

        let result = sysctl(&mib, u_int(mib.count), &argmaxValue, &valueSize, nil, 0)
        if result == 0, argmaxValue > 0 {
            return Int(argmaxValue)
        }

        return 262_144
    }

    private static func stringFromCCharTuple<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) { tuplePointer in
            tuplePointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { cStringPointer in
                guard cStringPointer.pointee != 0 else {
                    return ""
                }
                return String(cString: cStringPointer)
            }
        }
    }
}
#endif
