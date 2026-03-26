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

    private struct RegistrationCandidate {
        let loginPID: pid_t
        let shellPID: pid_t?
        let shellWorkingDirectory: String?
    }

    private let appPID: pid_t
    private var cachedProcessByPanelID: [UUID: CachedProcessEntry] = [:]
    /// Panels that failed initial PID snapshot diff (child not visible yet).
    /// The poll loop will attempt deferred registration by scanning app children.
    private var pendingDeferredRegistrationOrdinalByPanelID: [UUID: UInt64] = [:]
    private var nextPendingDeferredRegistrationOrdinal: UInt64 = 0
    /// Login PIDs whose shell children haven't spawned yet. Keyed by panel ID.
    /// Resolved during the next CWD poll cycle.
    private var pendingLoginPIDByPanelID: [UUID: pid_t] = [:]
    /// High-confidence live cwd captured at surface creation time. Used to avoid
    /// assigning a login/shell process to the wrong panel when multiple terminals
    /// spawn concurrently, but intentionally excludes restored launch seeds.
    private var expectedWorkingDirectoryByPanelID: [UUID: String] = [:]

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
    func registerNewChild(panelID: UUID, previousChildren: Set<pid_t>, expectedWorkingDirectory: String?) {
        if let canonicalExpectedWorkingDirectory = Self.canonicalWorkingDirectory(expectedWorkingDirectory) {
            expectedWorkingDirectoryByPanelID[panelID] = canonicalExpectedWorkingDirectory
        } else {
            expectedWorkingDirectoryByPanelID.removeValue(forKey: panelID)
        }

        let currentChildren = Set(childPIDs(of: appPID))
        let newChildren = currentChildren.subtracting(previousChildren)

        guard newChildren.isEmpty == false else {
            // Child not visible yet — mark for deferred registration during poll loop.
            markPendingDeferredRegistration(panelID: panelID)
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

        let candidates = registrationCandidates(
            from: Array(newChildren),
            reservedLoginPIDs: reservedLoginPIDs(excluding: panelID),
            knownShellPIDs: knownShellPIDs()
        )
        guard let selectedCandidate = selectRegistrationCandidate(
            panelID: panelID,
            candidates: candidates,
            preferNewestWhenAmbiguous: true
        ) else {
            markPendingDeferredRegistration(panelID: panelID)
            ToasttyLog.debug(
                "Ambiguous new child process candidates after surface creation; deferring registration",
                category: .terminal,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "candidate_count": String(candidates.count),
                ]
            )
            return
        }

        cacheLoginOrShell(panelID: panelID, loginPID: selectedCandidate.loginPID, source: "snapshot_diff")
    }

    // MARK: - CWD Resolution

    func resolveWorkingDirectory(for panelID: UUID) -> String? {
        // Attempt deferred registration if this panel was never registered.
        if pendingDeferredRegistrationOrdinalByPanelID[panelID] != nil {
            attemptDeferredRegistration(panelID: panelID)
        }

        // Try to resolve pending login → shell walk.
        if let loginPID = pendingLoginPIDByPanelID[panelID] {
            if let shellPID = resolvedShellPID(forLoginPID: loginPID),
               let signature = processStartSignature(pid: shellPID) {
                pendingLoginPIDByPanelID.removeValue(forKey: panelID)
                cachedProcessByPanelID[panelID] = CachedProcessEntry(
                    pid: shellPID,
                    startSignature: signature
                )
                expectedWorkingDirectoryByPanelID.removeValue(forKey: panelID)
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
        pendingDeferredRegistrationOrdinalByPanelID.removeValue(forKey: panelID)
        pendingLoginPIDByPanelID.removeValue(forKey: panelID)
        expectedWorkingDirectoryByPanelID.removeValue(forKey: panelID)
    }

    func prune(panelIDs: Set<UUID>) {
        cachedProcessByPanelID = cachedProcessByPanelID.filter { panelID, _ in
            panelIDs.contains(panelID)
        }
        pendingDeferredRegistrationOrdinalByPanelID = pendingDeferredRegistrationOrdinalByPanelID.filter { panelID, _ in
            panelIDs.contains(panelID)
        }
        pendingLoginPIDByPanelID = pendingLoginPIDByPanelID.filter { panelID, _ in
            panelIDs.contains(panelID)
        }
        expectedWorkingDirectoryByPanelID = expectedWorkingDirectoryByPanelID.filter { panelID, _ in
            panelIDs.contains(panelID)
        }
    }

    // MARK: - Registration Helpers

    /// Caches the shell child of a login PID for CWD tracking.
    ///
    /// The `login` process is root-owned and its info is unreadable via
    /// `proc_pidinfo`, so we must resolve the user-owned shell child.
    /// If the shell hasn't spawned yet, records the login PID for deferred
    /// resolution during the next poll cycle.
    private func cacheLoginOrShell(panelID: UUID, loginPID: pid_t, source: String) {
        pendingDeferredRegistrationOrdinalByPanelID.removeValue(forKey: panelID)

        if let shellPID = resolvedShellPID(forLoginPID: loginPID),
           let signature = processStartSignature(pid: shellPID) {
            cachedProcessByPanelID[panelID] = CachedProcessEntry(
                pid: shellPID,
                startSignature: signature
            )
            expectedWorkingDirectoryByPanelID.removeValue(forKey: panelID)
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
        let candidates = registrationCandidates(
            from: childPIDs(of: appPID),
            reservedLoginPIDs: reservedLoginPIDs(excluding: panelID),
            knownShellPIDs: knownShellPIDs()
        )
        if let selectedCandidate = selectRegistrationCandidate(
            panelID: panelID,
            candidates: candidates,
            preferNewestWhenAmbiguous: false
        ) {
            // Found an untracked child — assign it to this panel.
            cacheLoginOrShell(panelID: panelID, loginPID: selectedCandidate.loginPID, source: "deferred_scan")
            return
        }

        guard let selectedCandidate = selectDeferredRegistrationCandidate(
            panelID: panelID,
            candidates: candidates
        ) else {
            return
        }

        cacheLoginOrShell(panelID: panelID, loginPID: selectedCandidate.loginPID, source: "deferred_ordered_scan")
    }

    private func knownShellPIDs() -> Set<pid_t> {
        Set(cachedProcessByPanelID.values.map(\.pid))
    }

    private func reservedLoginPIDs(excluding panelID: UUID) -> Set<pid_t> {
        Set(
            pendingLoginPIDByPanelID.compactMap { candidatePanelID, loginPID in
                candidatePanelID == panelID ? nil : loginPID
            }
        )
    }

    private func registrationCandidates(
        from loginPIDs: [pid_t],
        reservedLoginPIDs: Set<pid_t>,
        knownShellPIDs: Set<pid_t>
    ) -> [RegistrationCandidate] {
        var seenLoginPIDs: Set<pid_t> = []
        var candidates: [RegistrationCandidate] = []
        for loginPID in loginPIDs.sorted() {
            guard seenLoginPIDs.insert(loginPID).inserted else { continue }
            guard !reservedLoginPIDs.contains(loginPID) else { continue }

            let loginChildren = childPIDs(of: loginPID).sorted()
            if loginChildren.contains(where: { knownShellPIDs.contains($0) }) {
                continue
            }
            let shellPID = resolvedShellPID(fromLoginChildren: loginChildren)
            let shellWorkingDirectory = shellPID
                .flatMap(processWorkingDirectory)
                .flatMap(Self.canonicalWorkingDirectory)
            candidates.append(
                RegistrationCandidate(
                    loginPID: loginPID,
                    shellPID: shellPID,
                    shellWorkingDirectory: shellWorkingDirectory
                )
            )
        }
        return candidates
    }

    private func markPendingDeferredRegistration(panelID: UUID) {
        guard pendingDeferredRegistrationOrdinalByPanelID[panelID] == nil else {
            return
        }
        pendingDeferredRegistrationOrdinalByPanelID[panelID] = nextPendingDeferredRegistrationOrdinal
        nextPendingDeferredRegistrationOrdinal += 1
    }

    private func selectDeferredRegistrationCandidate(
        panelID: UUID,
        candidates: [RegistrationCandidate]
    ) -> RegistrationCandidate? {
        let pendingPanelIDsByOrder = pendingDeferredRegistrationOrdinalByPanelID
            .sorted { lhs, rhs in lhs.value < rhs.value }
            .map(\.key)
        guard let candidateIndex = Self.deferredRegistrationCandidateIndex(
            panelID: panelID,
            pendingPanelIDsByOrder: pendingPanelIDsByOrder,
            candidateCount: candidates.count
        ) else {
            ToasttyLog.debug(
                "Deferred terminal process registration remains ambiguous",
                category: .terminal,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "candidate_count": String(candidates.count),
                    "pending_panel_count": String(pendingPanelIDsByOrder.count),
                ]
            )
            return nil
        }

        ToasttyLog.debug(
            "Assigning deferred terminal process candidate by launch order",
            category: .terminal,
            metadata: [
                "panel_id": panelID.uuidString,
                "candidate_index": String(candidateIndex),
                "candidate_count": String(candidates.count),
                "pending_panel_count": String(pendingPanelIDsByOrder.count),
            ]
        )
        return candidates[candidateIndex]
    }

    static func deferredRegistrationCandidateIndex(
        panelID: UUID,
        pendingPanelIDsByOrder: [UUID],
        candidateCount: Int
    ) -> Int? {
        // Only use ordered fallback when the pending-pane set and unclaimed
        // login-process set form an exact one-to-one mapping.
        guard candidateCount == pendingPanelIDsByOrder.count else {
            return nil
        }
        guard let panelIndex = pendingPanelIDsByOrder.firstIndex(of: panelID),
              panelIndex < candidateCount else {
            return nil
        }
        return panelIndex
    }

    static func preferredRegistrationCandidateIndex(
        expectedWorkingDirectory: String?,
        candidateWorkingDirectories: [String?],
        candidateLoginPIDs: [pid_t],
        preferNewestWhenAmbiguous: Bool
    ) -> Int? {
        guard candidateWorkingDirectories.count == candidateLoginPIDs.count else {
            return nil
        }
        guard candidateWorkingDirectories.isEmpty == false else {
            return nil
        }

        if let expectedWorkingDirectory = canonicalWorkingDirectory(expectedWorkingDirectory) {
            let matchingIndices = candidateWorkingDirectories.enumerated().compactMap { index, candidateWorkingDirectory in
                canonicalWorkingDirectory(candidateWorkingDirectory) == expectedWorkingDirectory ? index : nil
            }
            if matchingIndices.count == 1 {
                return matchingIndices[0]
            }
            if matchingIndices.isEmpty == false {
                guard preferNewestWhenAmbiguous else {
                    return matchingIndices[0]
                }
                return matchingIndices.max(by: { candidateLoginPIDs[$0] < candidateLoginPIDs[$1] })
            }
        }

        if candidateWorkingDirectories.count == 1 {
            return 0
        }
        if preferNewestWhenAmbiguous {
            return candidateLoginPIDs.indices.max(by: { candidateLoginPIDs[$0] < candidateLoginPIDs[$1] })
        }
        return nil
    }

    private func selectRegistrationCandidate(
        panelID: UUID,
        candidates: [RegistrationCandidate],
        preferNewestWhenAmbiguous: Bool
    ) -> RegistrationCandidate? {
        guard !candidates.isEmpty else { return nil }

        if let candidateIndex = Self.preferredRegistrationCandidateIndex(
            expectedWorkingDirectory: expectedWorkingDirectoryByPanelID[panelID],
            candidateWorkingDirectories: candidates.map(\.shellWorkingDirectory),
            candidateLoginPIDs: candidates.map(\.loginPID),
            preferNewestWhenAmbiguous: preferNewestWhenAmbiguous
        ) {
            if let expectedWorkingDirectory = expectedWorkingDirectoryByPanelID[panelID] {
                let matchingIndices = candidates.indices.filter {
                    Self.canonicalWorkingDirectory(candidates[$0].shellWorkingDirectory) == expectedWorkingDirectory
                }
                if matchingIndices.count > 1 {
                    ToasttyLog.debug(
                        "Multiple login candidates matched expected cwd; applying deterministic tiebreak",
                        category: .terminal,
                        metadata: [
                            "panel_id": panelID.uuidString,
                            "match_count": String(matchingIndices.count),
                            "expected_cwd": expectedWorkingDirectory,
                        ]
                    )
                }
            }
            return candidates[candidateIndex]
        }

        return nil
    }

    private static func canonicalWorkingDirectory(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let standardizedPath = (trimmed as NSString).standardizingPath
        guard standardizedPath.isEmpty == false else { return nil }
        guard standardizedPath.count > 1 else { return standardizedPath }
        if standardizedPath.hasSuffix("/") {
            return String(standardizedPath.dropLast())
        }
        return standardizedPath
    }

    private func resolvedShellPID(forLoginPID loginPID: pid_t) -> pid_t? {
        resolvedShellPID(fromLoginChildren: childPIDs(of: loginPID).sorted())
    }

    private func resolvedShellPID(fromLoginChildren loginChildren: [pid_t]) -> pid_t? {
        if let readableProcessPID = loginChildren.first(where: { processStartSignature(pid: $0) != nil }) {
            return readableProcessPID
        }
        return loginChildren.first
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
