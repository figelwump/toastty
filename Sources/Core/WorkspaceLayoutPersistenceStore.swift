import CryptoKit
import Foundation

public struct WorkspaceLayoutPersistenceLoadResult: Equatable, Sendable {
    public let layout: WorkspaceLayoutSnapshot
    public let resolvedProfileID: String
    public let profileSummary: WorkspaceLayoutPersistenceProfileSummary

    public init(
        layout: WorkspaceLayoutSnapshot,
        resolvedProfileID: String,
        profileSummary: WorkspaceLayoutPersistenceProfileSummary
    ) {
        self.layout = layout
        self.resolvedProfileID = resolvedProfileID
        self.profileSummary = profileSummary
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
    public static let currentFormatVersion = 2

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

            do {
                let restoredState = candidate.layout.makeAppState()
                try StateValidator.validate(restoredState)
                return WorkspaceLayoutPersistenceLoadResult(
                    layout: candidate.layout,
                    resolvedProfileID: candidateProfileID,
                    profileSummary: Self.profileSummary(
                        profileID: candidateProfileID,
                        profile: candidate
                    )
                )
            } catch {
                ToasttyLog.warning(
                    "Persisted workspace layout profile is invalid",
                    category: .state,
                    metadata: [
                        "path": fileURL.path,
                        "profile_id": candidateProfileID,
                        "error": error.localizedDescription,
                    ]
                )
            }
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
        maxProfileCount: Int = 8
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
        document.profiles[profileID] = WorkspaceLayoutPersistedProfile(
            updatedAt: Date(),
            layout: layout
        )

        if maxProfileCount > 0,
           document.profiles.count > maxProfileCount {
            let sortedByAge = document.profiles.sorted { lhs, rhs in
                lhs.value.updatedAt < rhs.value.updatedAt
            }
            let removals = sortedByAge.prefix(document.profiles.count - maxProfileCount)
            for removal in removals {
                document.profiles.removeValue(forKey: removal.key)
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: .atomic)
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
}

private struct WorkspaceLayoutPersistedProfile: Codable, Sendable {
    var updatedAt: Date
    var layout: WorkspaceLayoutSnapshot
}
