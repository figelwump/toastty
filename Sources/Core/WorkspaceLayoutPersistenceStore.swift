import CryptoKit
import Foundation

public struct WorkspaceLayoutPersistenceLoadResult: Equatable, Sendable {
    public let layout: WorkspaceLayoutSnapshot
    public let resolvedProfileID: String
    public let profileSummary: WorkspaceLayoutPersistenceProfileSummary
    public let migrationSourceProfileID: String?

    public init(
        layout: WorkspaceLayoutSnapshot,
        resolvedProfileID: String,
        profileSummary: WorkspaceLayoutPersistenceProfileSummary,
        migrationSourceProfileID: String? = nil
    ) {
        self.layout = layout
        self.resolvedProfileID = resolvedProfileID
        self.profileSummary = profileSummary
        self.migrationSourceProfileID = migrationSourceProfileID
    }
}

public struct WorkspaceLayoutPersistenceDiagnosticsSummary: Equatable, Sendable {
    public let formatVersion: Int
    public let profiles: [WorkspaceLayoutPersistenceProfileSummary]

    public init(formatVersion: Int, profiles: [WorkspaceLayoutPersistenceProfileSummary]) {
        self.formatVersion = formatVersion
        self.profiles = profiles
    }
}

public struct WorkspaceLayoutPersistenceProfileSummary: Equatable, Sendable {
    public let profileID: String
    public let updatedAt: Date
    public let windowCount: Int
    public let workspaceCount: Int
    public let tabCount: Int
    public let panelCount: Int
    public let fingerprint: String?
    public let validationError: String?

    public init(
        profileID: String,
        updatedAt: Date,
        windowCount: Int,
        workspaceCount: Int,
        tabCount: Int,
        panelCount: Int,
        fingerprint: String?,
        validationError: String?
    ) {
        self.profileID = profileID
        self.updatedAt = updatedAt
        self.windowCount = windowCount
        self.workspaceCount = workspaceCount
        self.tabCount = tabCount
        self.panelCount = panelCount
        self.fingerprint = fingerprint
        self.validationError = validationError
    }
}

public struct WorkspaceLayoutPersistenceStore: Sendable {
    public static let currentFormatVersion = 3
    public static let canonicalProfileID = "default"
    public static let legacyDisplayProfilePrefix = "display-"
    private static let legacyCanonicalRecoveryProfilePrefix = "recovery-default-pre-v3"

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func loadLayout(for profileID: String, fallbackProfileID: String? = nil) -> WorkspaceLayoutPersistenceLoadResult? {
        guard let document = loadDocument() else {
            return nil
        }

        let candidateProfileIDs = candidateProfileResolutionOrder(
            requestedProfileID: profileID,
            fallbackProfileID: fallbackProfileID,
            availableProfileIDs: Array(document.profiles.keys)
        )

        for candidateProfileID in candidateProfileIDs {
            guard let candidate = document.profiles[candidateProfileID] else {
                continue
            }
            if let result = validatedLoadResult(
                profileID: candidateProfileID,
                profile: candidate
            ) {
                return result
            }
        }

        return nil
    }

    public func loadLayoutExactly(for profileID: String) -> WorkspaceLayoutPersistenceLoadResult? {
        guard let document = loadDocument(),
              let profile = document.profiles[profileID] else {
            return nil
        }
        return validatedLoadResult(profileID: profileID, profile: profile)
    }

    /// Adopts one canonical layout for ordinary app launches while retaining
    /// every legacy display profile as a recovery copy.
    public func loadCanonicalLayout(
        for canonicalProfileID: String = Self.canonicalProfileID,
        isLegacyProfileID: (String) -> Bool
    ) -> WorkspaceLayoutPersistenceLoadResult? {
        guard var document = loadDocument() else {
            return nil
        }

        if document.canonicalProfileID == canonicalProfileID {
            guard let canonicalProfile = document.profiles[canonicalProfileID],
                  let canonicalResult = validatedLoadResult(
                      profileID: canonicalProfileID,
                      profile: canonicalProfile
                  ) else {
                ToasttyLog.warning(
                    "Canonical workspace layout is unavailable; refusing legacy profile fallback",
                    category: .state,
                    metadata: [
                        "path": fileURL.path,
                        "canonical_profile_id": canonicalProfileID,
                    ]
                )
                return nil
            }
            return canonicalResult
        }

        let candidates = document.profiles
            .filter { profileID, _ in
                profileID == canonicalProfileID || isLegacyProfileID(profileID)
            }
            .sorted { lhs, rhs in
                if lhs.value.updatedAt != rhs.value.updatedAt {
                    return lhs.value.updatedAt > rhs.value.updatedAt
                }
                return lhs.key < rhs.key
            }

        for (sourceProfileID, sourceProfile) in candidates {
            guard validatedLoadResult(
                profileID: sourceProfileID,
                profile: sourceProfile
            ) != nil else {
                continue
            }

            document.version = Self.currentFormatVersion
            document.canonicalProfileID = canonicalProfileID
            var preservedProfileID: String?
            if sourceProfileID != canonicalProfileID,
               let previousCanonicalProfile = document.profiles[canonicalProfileID] {
                let recoveryProfileID = Self.nextLegacyCanonicalRecoveryProfileID(
                    availableProfileIDs: Set(document.profiles.keys)
                )
                document.profiles[recoveryProfileID] = previousCanonicalProfile
                preservedProfileID = recoveryProfileID
            }
            document.profiles[canonicalProfileID] = sourceProfile

            let canonicalSummary = Self.profileSummary(
                profileID: canonicalProfileID,
                profile: sourceProfile
            )
            let migrationResult = WorkspaceLayoutPersistenceLoadResult(
                layout: sourceProfile.layout,
                resolvedProfileID: canonicalProfileID,
                profileSummary: canonicalSummary,
                migrationSourceProfileID: sourceProfileID == canonicalProfileID
                    ? nil
                    : sourceProfileID
            )

            do {
                try writeDocument(document)
            } catch {
                ToasttyLog.warning(
                    "Failed to migrate workspace layout to canonical profile",
                    category: .state,
                    metadata: [
                        "path": fileURL.path,
                        "source_profile_id": sourceProfileID,
                        "canonical_profile_id": canonicalProfileID,
                        "error": error.localizedDescription,
                    ]
                )
                return migrationResult
            }

            var migrationMetadata = [
                "path": fileURL.path,
                "source_profile_id": sourceProfileID,
                "canonical_profile_id": canonicalProfileID,
                "source_updated_at_ms": String(
                    Int64((sourceProfile.updatedAt.timeIntervalSince1970 * 1000).rounded())
                ),
                "profile_window_count": String(canonicalSummary.windowCount),
                "profile_workspace_count": String(canonicalSummary.workspaceCount),
                "profile_tab_count": String(canonicalSummary.tabCount),
                "profile_panel_count": String(canonicalSummary.panelCount),
                "profile_fingerprint": canonicalSummary.fingerprint ?? "unavailable",
            ]
            if let preservedProfileID {
                migrationMetadata["preserved_profile_id"] = preservedProfileID
            }
            ToasttyLog.info(
                "Migrated workspace layout to canonical profile",
                category: .state,
                metadata: migrationMetadata
            )
            return migrationResult
        }

        return nil
    }

    /// Reads a content-free summary of every persisted profile without
    /// migrating, repairing, or rewriting the layout document.
    public func diagnosticsSummary() throws -> WorkspaceLayoutPersistenceDiagnosticsSummary {
        let data = try Data(contentsOf: fileURL)
        let document = try JSONDecoder().decode(
            WorkspaceLayoutPersistenceDocument.self,
            from: data
        )
        return WorkspaceLayoutPersistenceDiagnosticsSummary(
            formatVersion: document.version,
            profiles: document.profiles
                .map { profileID, profile in
                    Self.profileSummary(profileID: profileID, profile: profile)
                }
                .sorted { $0.profileID < $1.profileID }
        )
    }

    public static func diagnosticsSummary(
        for layout: WorkspaceLayoutSnapshot,
        profileID: String,
        updatedAt: Date = Date()
    ) -> WorkspaceLayoutPersistenceProfileSummary {
        profileSummary(
            profileID: profileID,
            updatedAt: updatedAt,
            layout: layout
        )
    }

    /// Counts persisted workspace annotations outside the profiles represented
    /// by the caller's live AppState. Excluding those profiles prevents their
    /// debounced on-disk snapshots from overriding newer in-memory mutations.
    public func annotationUsageCounts(
        excludingProfileIDs: Set<String>
    ) throws -> [String: Int] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }

        let data = try Data(contentsOf: fileURL)
        let document = try JSONDecoder().decode(
            WorkspaceLayoutPersistenceDocument.self,
            from: data
        )

        return document.profiles.reduce(into: [String: Int]()) { counts, entry in
            guard excludingProfileIDs.contains(entry.key) == false else { return }
            for workspace in entry.value.layout.workspacesByID.values {
                for key in workspace.annotations.keys {
                    counts[key, default: 0] += 1
                }
            }
        }
    }

    @discardableResult
    public func persistLayout(
        _ layout: WorkspaceLayoutSnapshot,
        for profileID: String,
        maxProfileCount: Int = 8,
        updatedAt: Date = Date()
    ) -> Bool {
        do {
            try StateValidator.validate(layout.makeAppState())
        } catch {
            ToasttyLog.warning(
                "Skipping workspace layout persistence because state is invalid",
                category: .state,
                metadata: [
                    "path": fileURL.path,
                    "profile_id": profileID,
                    "error": error.localizedDescription,
                ]
            )
            return false
        }

        var document = loadDocument() ?? WorkspaceLayoutPersistenceDocument(version: Self.currentFormatVersion, profiles: [:])
        document.version = Self.currentFormatVersion
        if profileID == Self.canonicalProfileID {
            document.canonicalProfileID = Self.canonicalProfileID
        }
        document.profiles[profileID] = WorkspaceLayoutPersistedProfile(
            updatedAt: updatedAt,
            layout: layout
        )

        if maxProfileCount > 0,
           document.profiles.count > maxProfileCount {
            let sortedByAge = document.profiles.sorted { lhs, rhs in
                lhs.value.updatedAt < rhs.value.updatedAt
            }
            let overflow = document.profiles.count - maxProfileCount
            let removals = sortedByAge
                .filter { entry in
                    Self.isProtectedProfileID(entry.key, currentProfileID: profileID) == false
                }
                .prefix(overflow)
            for removal in removals {
                document.profiles.removeValue(forKey: removal.key)
            }
        }

        do {
            try writeDocument(document)
            return true
        } catch {
            ToasttyLog.warning(
                "Failed to persist workspace layout profile",
                category: .state,
                metadata: [
                    "path": fileURL.path,
                    "profile_id": profileID,
                    "error": error.localizedDescription,
                ]
            )
            return false
        }
    }

    private func loadDocument() -> WorkspaceLayoutPersistenceDocument? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            return try decoder.decode(WorkspaceLayoutPersistenceDocument.self, from: data)
        } catch {
            ToasttyLog.warning(
                "Failed to decode workspace layout persistence file",
                category: .state,
                metadata: [
                    "path": fileURL.path,
                    "error": error.localizedDescription,
                ]
            )
            return nil
        }
    }

    private func writeDocument(_ document: WorkspaceLayoutPersistenceDocument) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
    }

    private func validatedLoadResult(
        profileID: String,
        profile: WorkspaceLayoutPersistedProfile
    ) -> WorkspaceLayoutPersistenceLoadResult? {
        do {
            let restoredState = profile.layout.makeAppState()
            try StateValidator.validate(restoredState)
            return WorkspaceLayoutPersistenceLoadResult(
                layout: profile.layout,
                resolvedProfileID: profileID,
                profileSummary: Self.profileSummary(
                    profileID: profileID,
                    profile: profile
                )
            )
        } catch {
            ToasttyLog.warning(
                "Persisted workspace layout profile is invalid",
                category: .state,
                metadata: [
                    "path": fileURL.path,
                    "profile_id": profileID,
                    "error": error.localizedDescription,
                ]
            )
            return nil
        }
    }

    private static func isProtectedProfileID(
        _ profileID: String,
        currentProfileID: String
    ) -> Bool {
        profileID == currentProfileID
            || profileID == canonicalProfileID
            || profileID.hasPrefix(legacyDisplayProfilePrefix)
            || profileID == legacyCanonicalRecoveryProfilePrefix
            || profileID.hasPrefix("\(legacyCanonicalRecoveryProfilePrefix)-")
    }

    private static func nextLegacyCanonicalRecoveryProfileID(
        availableProfileIDs: Set<String>
    ) -> String {
        if availableProfileIDs.contains(legacyCanonicalRecoveryProfilePrefix) == false {
            return legacyCanonicalRecoveryProfilePrefix
        }

        var suffix = 2
        while availableProfileIDs.contains("\(legacyCanonicalRecoveryProfilePrefix)-\(suffix)") {
            suffix += 1
        }
        return "\(legacyCanonicalRecoveryProfilePrefix)-\(suffix)"
    }

    private func candidateProfileResolutionOrder(
        requestedProfileID: String,
        fallbackProfileID: String?,
        availableProfileIDs: [String]
    ) -> [String] {
        var ordered: [String] = []

        ordered.append(requestedProfileID)

        if let fallbackProfileID,
           fallbackProfileID.isEmpty == false,
           fallbackProfileID != requestedProfileID {
            ordered.append(fallbackProfileID)
        }

        if availableProfileIDs.count == 1,
           let onlyProfileID = availableProfileIDs.first,
           ordered.contains(onlyProfileID) == false {
            ordered.append(onlyProfileID)
        }

        return ordered
    }

    private static func profileSummary(
        profileID: String,
        profile: WorkspaceLayoutPersistedProfile
    ) -> WorkspaceLayoutPersistenceProfileSummary {
        profileSummary(
            profileID: profileID,
            updatedAt: profile.updatedAt,
            layout: profile.layout
        )
    }

    private static func profileSummary(
        profileID: String,
        updatedAt: Date,
        layout: WorkspaceLayoutSnapshot
    ) -> WorkspaceLayoutPersistenceProfileSummary {
        let tabs = layout.workspacesByID.values.flatMap { $0.tabsByID.values }
        let validationError: String?
        do {
            try StateValidator.validate(layout.makeAppState())
            validationError = nil
        } catch {
            validationError = error.localizedDescription
        }

        return WorkspaceLayoutPersistenceProfileSummary(
            profileID: profileID,
            updatedAt: updatedAt,
            windowCount: layout.windows.count,
            workspaceCount: layout.workspacesByID.count,
            tabCount: tabs.count,
            panelCount: tabs.reduce(0) { $0 + $1.panels.count },
            fingerprint: layoutFingerprint(layout),
            validationError: validationError
        )
    }

    private static func layoutFingerprint(_ layout: WorkspaceLayoutSnapshot) -> String? {
        var fingerprint = WorkspaceLayoutTopologyFingerprint()
        fingerprint.append("toastty-workspace-layout-topology-v1")
        fingerprint.append(layout.selectedWindowID)
        fingerprint.append(layout.windows.count)
        for window in layout.windows {
            fingerprint.append(window.id)
            fingerprint.append(window.frame.x)
            fingerprint.append(window.frame.y)
            fingerprint.append(window.frame.width)
            fingerprint.append(window.frame.height)
            fingerprint.append(window.workspaceIDs)
            fingerprint.append(window.selectedWorkspaceID)
            fingerprint.append(window.sidebarVisible)
            fingerprint.append(window.sidebarWidthPointsOverride)
            fingerprint.append(window.terminalFontSizePointsOverride)
            fingerprint.append(window.markdownTextScaleOverride)
        }

        let workspaces = layout.workspacesByID.sorted {
            $0.key.uuidString < $1.key.uuidString
        }
        fingerprint.append(workspaces.count)
        for (workspaceKey, workspace) in workspaces {
            fingerprint.append(workspaceKey)
            fingerprint.append(workspace.id)
            fingerprint.append(workspace.selectedTabID)
            fingerprint.append(workspace.tabIDs)

            let tabs = workspace.tabsByID.sorted {
                $0.key.uuidString < $1.key.uuidString
            }
            fingerprint.append(tabs.count)
            for (tabKey, tab) in tabs {
                fingerprint.append(tabKey)
                fingerprint.append(tab.id)
                fingerprint.append(tab.focusedPanelID)
                fingerprint.append(tab.layoutTree)

                let panels = tab.panels.sorted {
                    $0.key.uuidString < $1.key.uuidString
                }
                fingerprint.append(panels.count)
                for (panelID, panel) in panels {
                    fingerprint.append(panelID)
                    fingerprint.append(panel)
                }

                let rightAuxPanel = tab.rightAuxPanel
                fingerprint.append(rightAuxPanel.isVisible)
                fingerprint.append(rightAuxPanel.width)
                fingerprint.append(rightAuxPanel.hasCustomWidth)
                fingerprint.append(rightAuxPanel.activeTabID)
                fingerprint.append(rightAuxPanel.tabIDs)
                let rightAuxTabs = rightAuxPanel.tabsByID.sorted {
                    $0.key.uuidString < $1.key.uuidString
                }
                fingerprint.append(rightAuxTabs.count)
                for (rightAuxTabKey, rightAuxTab) in rightAuxTabs {
                    fingerprint.append(rightAuxTabKey)
                    fingerprint.append(rightAuxTab.id)
                    fingerprint.append(rightAuxTab.panelID)
                    fingerprint.append(rightAuxTab.identity)
                    fingerprint.append(rightAuxTab.panelState.kind.rawValue)
                }
            }
        }

        return fingerprint.finalize()
    }
}

private struct WorkspaceLayoutTopologyFingerprint {
    private var data = Data()

    mutating func append(_ value: String) {
        let bytes = Data(value.utf8)
        let length = UInt64(bytes.count)
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: length >> 56),
            UInt8(truncatingIfNeeded: length >> 48),
            UInt8(truncatingIfNeeded: length >> 40),
            UInt8(truncatingIfNeeded: length >> 32),
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ])
        data.append(bytes)
    }

    mutating func append(_ value: Int) {
        append(String(value))
    }

    mutating func append(_ value: Bool) {
        append(value ? "true" : "false")
    }

    mutating func append(_ value: Double) {
        append(String(value.bitPattern))
    }

    mutating func append(_ value: Double?) {
        append(value.map { String($0.bitPattern) } ?? "none")
    }

    mutating func append(_ value: UUID) {
        append(value.uuidString)
    }

    mutating func append(_ value: UUID?) {
        append(value?.uuidString ?? "none")
    }

    mutating func append(_ values: [UUID]) {
        append(values.count)
        for value in values {
            append(value)
        }
    }

    mutating func append(_ layoutNode: LayoutNode) {
        switch layoutNode {
        case .slot(let slotID, let panelID):
            append("slot")
            append(slotID)
            append(panelID)
        case .split(let nodeID, let orientation, let ratio, let first, let second):
            append("split")
            append(nodeID)
            append(orientation.rawValue)
            append(ratio)
            append(first)
            append(second)
        }
    }

    mutating func append(_ panel: WorkspaceLayoutPanelSnapshot) {
        switch panel {
        case .terminal:
            append("terminal")
        case .web(let webPanel):
            append("web")
            append(webPanel.definition.rawValue)
        }
    }

    mutating func append(_ identity: RightAuxPanelTabIdentity) {
        switch identity {
        case .localDocument:
            append("local_document")
        case .scratchpad(let id):
            append("scratchpad")
            append(id)
        case .diff(let id):
            append("diff")
            append(id)
        case .browserSession(let id):
            append("browser_session")
            append(id)
        }
    }

    func finalize() -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct WorkspaceLayoutPersistenceDocument: Codable, Sendable {
    var version: Int
    var profiles: [String: WorkspaceLayoutPersistedProfile]
    var canonicalProfileID: String?
}

private struct WorkspaceLayoutPersistedProfile: Codable, Sendable {
    var updatedAt: Date
    var layout: WorkspaceLayoutSnapshot
}
