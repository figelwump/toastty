import Foundation

public struct WorkspaceLayoutPersistenceLoadResult: Equatable, Sendable {
    public let layout: WorkspaceLayoutSnapshot
    public let resolvedProfileID: String

    public init(layout: WorkspaceLayoutSnapshot, resolvedProfileID: String) {
        self.layout = layout
        self.resolvedProfileID = resolvedProfileID
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
                    resolvedProfileID: candidateProfileID
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
}

private struct WorkspaceLayoutPersistenceDocument: Codable, Sendable {
    var version: Int
    var profiles: [String: WorkspaceLayoutPersistedProfile]
}

private struct WorkspaceLayoutPersistedProfile: Codable, Sendable {
    var updatedAt: Date
    var layout: WorkspaceLayoutSnapshot
}
