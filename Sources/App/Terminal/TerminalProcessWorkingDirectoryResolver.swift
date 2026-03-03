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
        /// When true, `pid` is the intermediate `login` process and needs to be
        /// upgraded to its shell child on the next resolution attempt.
        let needsShellWalk: Bool
    }

    private let appPID: pid_t
    private var cachedProcessByPanelID: [UUID: CachedProcessEntry] = [:]
    /// Panels that failed initial PID snapshot diff (child not visible yet).
    /// The poll loop will attempt deferred registration by scanning app children.
    private var pendingDeferredRegistration: Set<UUID> = []

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

        guard var entry = cachedProcessByPanelID[panelID] else {
            return nil
        }

        // If we cached the login PID, try to upgrade to the shell child now.
        if entry.needsShellWalk {
            let children = childPIDs(of: entry.pid)
            if let shellPID = children.first,
               let shellSignature = processStartSignature(pid: shellPID) {
                let upgraded = CachedProcessEntry(
                    pid: shellPID,
                    startSignature: shellSignature,
                    needsShellWalk: false
                )
                cachedProcessByPanelID[panelID] = upgraded
                entry = upgraded
                ToasttyLog.debug(
                    "Upgraded cached login PID to shell PID",
                    category: .terminal,
                    metadata: [
                        "panel_id": panelID.uuidString,
                        "shell_pid": String(shellPID),
                    ]
                )
            } else {
                // Shell still not spawned — read CWD from login PID as fallback.
                // The login process CWD is typically the user's home directory,
                // which is better than nothing while the shell starts up.
            }
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
    }

    // MARK: - Registration Helpers

    /// Caches a login PID, immediately walking to the shell child if available.
    /// If the shell hasn't spawned yet, caches the login PID with `needsShellWalk=true`
    /// so the next poll can upgrade it without blocking.
    private func cacheLoginOrShell(panelID: UUID, loginPID: pid_t, source: String) {
        pendingDeferredRegistration.remove(panelID)

        let children = childPIDs(of: loginPID)
        let resolvedPID: pid_t
        let needsShellWalk: Bool

        if let shellPID = children.first {
            resolvedPID = shellPID
            needsShellWalk = false
        } else {
            // Shell not spawned yet — cache login PID and upgrade lazily.
            resolvedPID = loginPID
            needsShellWalk = true
        }

        guard let signature = processStartSignature(pid: resolvedPID) else {
            ToasttyLog.warning(
                "Could not read start signature for new terminal process",
                category: .terminal,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "login_pid": String(loginPID),
                    "resolved_pid": String(resolvedPID),
                    "source": source,
                ]
            )
            return
        }

        cachedProcessByPanelID[panelID] = CachedProcessEntry(
            pid: resolvedPID,
            startSignature: signature,
            needsShellWalk: needsShellWalk
        )

        ToasttyLog.debug(
            "Registered terminal process for panel",
            category: .terminal,
            metadata: [
                "panel_id": panelID.uuidString,
                "login_pid": String(loginPID),
                "resolved_pid": String(resolvedPID),
                "needs_shell_walk": needsShellWalk ? "true" : "false",
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

    /// Returns direct child PIDs of `parentPID` using `proc_listchildpids`.
    private func childPIDs(of parentPID: pid_t) -> [pid_t] {
        // First call with nil buffer to get the count of child PIDs.
        let estimatedBytes = proc_listchildpids(parentPID, nil, 0)
        guard estimatedBytes > 0 else { return [] }

        let pidSize = MemoryLayout<pid_t>.stride
        // Over-allocate slightly in case new children appear between calls.
        let capacity = Int(estimatedBytes) / pidSize + 8
        var pids = Array(repeating: pid_t(0), count: capacity)

        let returnedBytes = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return proc_listchildpids(parentPID, base, Int32(buffer.count * pidSize))
        }

        guard returnedBytes > 0 else { return [] }
        let count = Int(returnedBytes) / pidSize
        return Array(pids.prefix(count).filter { $0 > 0 })
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
