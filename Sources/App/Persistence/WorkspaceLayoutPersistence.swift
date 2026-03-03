import AppKit
import CoreState
import Foundation

struct WorkspaceLayoutPersistenceContext {
    let profileID: String
    let fileURL: URL

    static func resolve(processInfo: ProcessInfo = .processInfo) -> WorkspaceLayoutPersistenceContext {
        WorkspaceLayoutPersistenceContext(
            profileID: WorkspaceLayoutProfileResolver.resolve(processInfo: processInfo),
            fileURL: WorkspaceLayoutPersistenceLocation.fileURL()
        )
    }

    func loadState() -> (state: AppState, resolvedProfileID: String)? {
        let store = WorkspaceLayoutPersistenceStore(fileURL: fileURL)
        guard let loadResult = store.loadLayout(
            for: profileID,
            fallbackProfileID: WorkspaceLayoutProfileResolver.fallbackProfileID
        ) else {
            return nil
        }
        return (loadResult.layout.makeAppState(), loadResult.resolvedProfileID)
    }
}

@MainActor
final class WorkspaceLayoutPersistenceCoordinator {
    private static let persistDebounceNanoseconds: UInt64 = 250_000_000

    private let context: WorkspaceLayoutPersistenceContext
    private let store: WorkspaceLayoutPersistenceStore
    private var pendingPersistTask: Task<Void, Never>?
    private var lastPersistedLayout: WorkspaceLayoutSnapshot?

    init(context: WorkspaceLayoutPersistenceContext) {
        self.context = context
        store = WorkspaceLayoutPersistenceStore(fileURL: context.fileURL)
    }

    deinit {
        pendingPersistTask?.cancel()
    }

    func handleAppliedAction(_ action: AppAction, previousState: AppState, nextState: AppState) {
        let previousLayout = WorkspaceLayoutSnapshot(state: previousState)
        let nextLayout = WorkspaceLayoutSnapshot(state: nextState)
        guard previousLayout != nextLayout else { return }
        schedulePersist(layout: nextLayout, reason: "action_\(action.logName)")
    }

    func flushCurrentState(_ state: AppState, reason: String) {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        persistNow(layout: WorkspaceLayoutSnapshot(state: state), reason: reason)
    }

    private func schedulePersist(layout: WorkspaceLayoutSnapshot, reason: String) {
        pendingPersistTask?.cancel()
        pendingPersistTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.persistDebounceNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            guard Task.isCancelled == false else { return }
            self.persistNow(layout: layout, reason: reason)
        }
    }

    private func persistNow(layout: WorkspaceLayoutSnapshot, reason: String) {
        guard layout != lastPersistedLayout else { return }

        guard store.persistLayout(layout, for: context.profileID) else {
            return
        }

        lastPersistedLayout = layout
        ToasttyLog.debug(
            "Persisted workspace layout",
            category: .state,
            metadata: [
                "profile_id": context.profileID,
                "reason": reason,
                "path": context.fileURL.path,
            ]
        )
    }
}

enum WorkspaceLayoutPersistenceLocation {
    private static let configDirectoryName = ".config/toastty"
    private static let fileName = "workspace-layout-profiles.json"

    static func fileURL(homeDirectoryPath: String = NSHomeDirectory()) -> URL {
        URL(filePath: homeDirectoryPath)
            .appending(path: configDirectoryName, directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }
}

enum WorkspaceLayoutProfileResolver {
    static let fallbackProfileID = "default"
    private static let profileOverrideEnvironmentKey = "TOASTTY_LAYOUT_PROFILE"

    static func resolve(processInfo: ProcessInfo = .processInfo) -> String {
        if let override = normalizedOverride(from: processInfo.environment[profileOverrideEnvironmentKey]) {
            return override
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return fallbackProfileID
        }

        let pixelWidth = max(1, Int((screen.frame.width * screen.backingScaleFactor).rounded()))
        let pixelHeight = max(1, Int((screen.frame.height * screen.backingScaleFactor).rounded()))
        let scaleLabel = formattedScale(screen.backingScaleFactor)
        return "display-\(pixelWidth)x\(pixelHeight)@\(scaleLabel)x"
    }

    private static func normalizedOverride(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let normalized = trimmed.lowercased().map { character -> Character in
            switch character {
            case "a"..."z", "0"..."9", "-", "_", ".":
                return character
            default:
                return "-"
            }
        }

        let collapsed = String(normalized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")

        guard collapsed.isEmpty == false else {
            return nil
        }

        return String(collapsed.prefix(80))
    }

    private static func formattedScale(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(rounded - value) < 0.0001 {
            return String(Int(rounded))
        }
        return String(format: "%.2f", value)
    }
}
