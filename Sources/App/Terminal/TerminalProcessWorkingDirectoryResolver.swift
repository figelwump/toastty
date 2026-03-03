#if TOASTTY_HAS_GHOSTTY_KIT
import CoreState
import Darwin
import Foundation

/// Tracks terminal shell processes by PID-snapshot-diffing at surface creation time,
/// then reads CWD via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.
///
/// Process hierarchy spawned by Ghostty:
/// ```
/// ToasttyApp (PID X)
/// ├── login (PID A) → zsh (PID B)   ← panel 1
/// └── login (PID C) → zsh (PID D)   ← panel 2
/// ```
///
/// The previous env-var-injection approach failed because `/usr/bin/login` creates
/// a clean environment, stripping any injected `TOASTTY_PANEL_ID`.
///
/// This implementation snapshots app child PIDs before surface creation, diffs after
/// to find the new `login` child, walks to its shell grandchild, and caches that
/// PID for fast CWD queries. If the shell hasn't spawned yet when registration
/// runs, the login PID is cached and upgraded to the shell PID lazily during the
/// next CWD poll.
final class TerminalProcessWorkingDirectoryResolver {
    private struct ProcessStartSignature: Equatable {
        let seconds: UInt64
        let microseconds: UInt64
    }

    private struct CachedProcessEntry {
        let pid: pid_t
        let startSignature: ProcessStartSignature
    }

    private let appPID: pid_t
    private var cachedProcessByPanelID: [UUID: CachedProcessEntry] = [:]
    /// Panels that failed initial PID snapshot diff (child not visible yet).
    /// The poll loop will attempt deferred registration by scanning app children.
    private var pendingDeferredRegistration: Set<UUID> = []
    /// Login PIDs whose shell children haven't spawned yet. Keyed by panel ID.
    /// Resolved during the next CWD poll cycle.
    private var pendingLoginPIDByPanelID: [UUID: pid_t] = [:]

    init() {
        appPID = getpid()
    }

    // MARK: - PID Snapshot API

    /// Snapshot direct child PIDs of this app process. Call immediately before surface creation.
    func snapshotChildPIDs() -> Set<pid_t> {
        Set(childPIDs(of: appPID))
    }

    /// After surface creation, diff current children against the pre-creation snapshot
    /// to find the newly spawned login/shell process. Non-blocking — if the shell
    /// hasn't spawned yet, caches the login PID and upgrades lazily during CWD polls.
    func registerNewChild(panelID: UUID, previousChildren: Set<pid_t>) {
        let currentChildren = Set(childPIDs(of: appPID))
        let newChildren = currentChildren.subtracting(previousChildren)

        guard let newLoginPID = newChildren.first else {
            // Child not visible yet — mark for deferred registration during poll loop.
            pendingDeferredRegistration.insert(panelID)
            ToasttyLog.debug(
                "No new child process detected after surface creation; deferring registration",
                category: .terminal,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "previous_child_count": String(previousChildren.count),
                    "current_child_count": String(currentChildren.count),
                ]
            )
            return
        }

        cacheLoginOrShell(panelID: panelID, loginPID: newLoginPID, source: "snapshot_diff")
    }

    // MARK: - CWD Resolution

    func resolveWorkingDirectory(for panelID: UUID) -> String? {
        // Attempt deferred registration if this panel was never registered.
        if pendingDeferredRegistration.contains(panelID) {
            attemptDeferredRegistration(panelID: panelID)
        }

        // Try to resolve pending login → shell walk.
        if let loginPID = pendingLoginPIDByPanelID[panelID] {
            let children = childPIDs(of: loginPID)
            if let shellPID = children.first,
               let signature = processStartSignature(pid: shellPID) {
                pendingLoginPIDByPanelID.removeValue(forKey: panelID)
                cachedProcessByPanelID[panelID] = CachedProcessEntry(
                    pid: shellPID,
                    startSignature: signature
                )
                ToasttyLog.debug(
                    "Resolved deferred login→shell for panel",
                    category: .terminal,
                    metadata: [
                        "panel_id": panelID.uuidString,
                        "login_pid": String(loginPID),
                        "shell_pid": String(shellPID),
                    ]
                )
            }
        }

        guard let entry = cachedProcessByPanelID[panelID] else {
            return nil
        }

        // Validate the cached PID is still the same process (not recycled).
        guard let currentSignature = processStartSignature(pid: entry.pid),
              currentSignature == entry.startSignature else {
            cachedProcessByPanelID.removeValue(forKey: panelID)
            ToasttyLog.debug(
                "Invalidated cached terminal process (PID recycled or exited)",
                category: .terminal,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "pid": String(entry.pid),
                ]
            )
            return nil
        }

        return processWorkingDirectory(pid: entry.pid)
    }

    func invalidate(panelID: UUID) {
        cachedProcessByPanelID.removeValue(forKey: panelID)
        pendingDeferredRegistration.remove(panelID)
        pendingLoginPIDByPanelID.removeValue(forKey: panelID)
    }

    // MARK: - Registration Helpers

    /// Caches the shell child of a login PID for CWD tracking.
    ///
    /// The `login` process is root-owned and its info is unreadable via
    /// `proc_pidinfo`, so we must resolve the user-owned shell child.
    /// If the shell hasn't spawned yet, records the login PID for deferred
    /// resolution during the next poll cycle.
    private func cacheLoginOrShell(panelID: UUID, loginPID: pid_t, source: String) {
        pendingDeferredRegistration.remove(panelID)

        let children = childPIDs(of: loginPID)
        if let shellPID = children.first,
           let signature = processStartSignature(pid: shellPID) {
            cachedProcessByPanelID[panelID] = CachedProcessEntry(
                pid: shellPID,
                startSignature: signature
            )
            ToasttyLog.debug(
                "Registered terminal process for panel",
                category: .terminal,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "login_pid": String(loginPID),
                    "shell_pid": String(shellPID),
                    "source": source,
                ]
            )
            return
        }

        // Shell not spawned yet — record login PID for deferred resolution.
        // We can't cache the login PID directly because it's root-owned and
        // proc_pidinfo can't read its info or CWD.
        pendingLoginPIDByPanelID[panelID] = loginPID
        ToasttyLog.debug(
            "Shell not spawned yet for login process; deferring shell resolution",
            category: .terminal,
            metadata: [
                "panel_id": panelID.uuidString,
                "login_pid": String(loginPID),
                "source": source,
            ]
        )
    }

    /// For panels where the initial snapshot diff missed the child process,
    /// scan current app children and try to find the untracked one.
    private func attemptDeferredRegistration(panelID: UUID) {
        let currentAppChildren = Set(childPIDs(of: appPID))
        let knownPIDs = Set(cachedProcessByPanelID.values.map(\.pid))

        // Find app children that aren't tracked by any panel yet.
        // Also check their login children (shell PIDs) against known PIDs.
        for candidatePID in currentAppChildren {
            guard !knownPIDs.contains(candidatePID) else { continue }
            let loginChildren = childPIDs(of: candidatePID)
            let shellPID = loginChildren.first
            if let shellPID, knownPIDs.contains(shellPID) { continue }

            // Found an untracked child — assign it to this panel.
            cacheLoginOrShell(panelID: panelID, loginPID: candidatePID, source: "deferred_scan")
            return
        }
    }

    // MARK: - Low-Level Process Helpers

    /// Returns child PIDs of `parentPID` using `proc_listpids(PROC_PPID_ONLY)`.
    ///
    /// We use `PROC_PPID_ONLY` instead of `proc_listchildpids` because the latter
    /// silently skips children owned by a different UID (e.g. root-owned `login`
    /// processes spawned by Ghostty). `PROC_PPID_ONLY` returns all children
    /// regardless of UID.
    private func childPIDs(of parentPID: pid_t) -> [pid_t] {
        let pidSize = MemoryLayout<pid_t>.stride
        let minimumCapacity = 64
        let maximumCapacity = Int(Int32.max) / pidSize

        // Probe for the current child list size, then over-allocate slightly.
        // Children can still spawn between calls, so we may need to retry.
        let probedBytes = Int(
            proc_listpids(
                UInt32(PROC_PPID_ONLY),
                UInt32(parentPID),
                nil,
                0
            )
        )
        var capacity = minimumCapacity
        if probedBytes > 0 {
            let probedCount = probedBytes / pidSize
            let adjustedProbeCount = probedCount + (probedBytes % pidSize == 0 ? 0 : 1)
            capacity = max(minimumCapacity, adjustedProbeCount + 8)
        }

        while true {
            var pids = Array(repeating: pid_t(0), count: capacity)
            let returnedBytes = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return 0 }
                return proc_listpids(
                    UInt32(PROC_PPID_ONLY),
                    UInt32(parentPID),
                    UnsafeMutableRawPointer(base),
                    Int32(buffer.count * pidSize)
                )
            }

            guard returnedBytes > 0 else { return [] }
            let count = Int(returnedBytes) / pidSize
            let filledBuffer = count >= capacity

            if filledBuffer == false {
                return Array(pids.prefix(count).filter { $0 > 0 })
            }

            if capacity >= maximumCapacity {
                ToasttyLog.warning(
                    "Reached maximum child PID buffer capacity; child PID list may be truncated",
                    category: .terminal,
                    metadata: [
                        "parent_pid": String(parentPID),
                        "capacity": String(capacity),
                    ]
                )
                return Array(pids.prefix(count).filter { $0 > 0 })
            }

            capacity = min(capacity * 2, maximumCapacity)
        }
    }

    private func processStartSignature(pid: pid_t) -> ProcessStartSignature? {
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

        return ProcessStartSignature(
            seconds: UInt64(info.pbi_start_tvsec),
            microseconds: UInt64(info.pbi_start_tvusec)
        )
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
}
#endif
