import AppKit
import CoreState
import Foundation
import RemoteProtocol

struct ManagedAgentSkillsProvisionedNotice: Equatable, Sendable {
    let windowID: UUID
    let agent: AgentKind
    let shippedSkillCount: Int
    /// Number of user skill packages delivered with this launch; 0 when the
    /// launch went shipped-only.
    let deliveredUserSkillCount: Int
}

struct ManagedCodexSkillsUnavailableNotice: Equatable, Sendable {
    let windowID: UUID
    let reasonCode: String
    let detail: String
}

enum ManagedAgentSkillsProvisionedNoticeStore {
    static func didShowKey(for agent: AgentKind) -> String {
        "toastty.\(agent.rawValue)SkillsProvisionedNoticeDidShow"
    }

    static func claim(
        for windowID: UUID,
        notificationObject: Any?,
        userDefaults: UserDefaults = ToasttyAppDefaults.current
    ) -> ManagedAgentSkillsProvisionedNotice? {
        guard let notice = notificationObject as? ManagedAgentSkillsProvisionedNotice,
              notice.windowID == windowID,
              userDefaults.bool(forKey: didShowKey(for: notice.agent)) == false else {
            return nil
        }
        userDefaults.set(true, forKey: didShowKey(for: notice.agent))
        return notice
    }
}

@MainActor
final class CodexSkillsManagementModel: ObservableObject {
    @Published private(set) var status: CodexSkillsStatus?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var codexNotFoundMessage: String?

    private let manager: CodexSkillsManager
    private let processPathProvider: @Sendable () -> String?
    private let processPathRefreshProvider: @Sendable () -> String?
    private var task: Task<Void, Never>?

    init(
        manager: CodexSkillsManager = CodexSkillsManager(),
        processPathProvider: @escaping @Sendable () -> String? = { nil },
        processPathRefreshProvider: (@Sendable () -> String?)? = nil
    ) {
        self.manager = manager
        self.processPathProvider = processPathProvider
        self.processPathRefreshProvider = processPathRefreshProvider ?? processPathProvider
    }

    func refresh(
        hasActiveManagedCodexSession: Bool,
        refreshProcessPath: Bool = false
    ) {
        runOperation(refreshProcessPath: refreshProcessPath) { manager, runtime in
            return manager.status(
                runtime: runtime,
                hasActiveManagedCodexSession: hasActiveManagedCodexSession
            )
        }
    }

    func repair() {
        runOperation(refreshProcessPath: true) { manager, runtime in
            return try manager.repair(runtime: runtime)
        }
    }

}

@MainActor
final class ClaudeSkillsManagementModel: ObservableObject {
    @Published private(set) var status: ClaudeSkillsDeliveryStatus?
    @Published private(set) var isWorking = false

    private let statusProvider: @Sendable () async -> ClaudeSkillsDeliveryStatus

    init(manager: any ClaudeSkillsBundleManaging = ClaudeSkillsBundleManager()) {
        statusProvider = { await manager.deliveryStatus() }
    }

    init(statusProvider: @escaping @Sendable () async -> ClaudeSkillsDeliveryStatus) {
        self.statusProvider = statusProvider
    }

    func refresh() {
        guard isWorking == false else { return }
        isWorking = true
        Task { [weak self, statusProvider] in
            let status = await statusProvider()
            guard let self else { return }
            self.status = status
            isWorking = false
        }
    }
}

/// Read-only view model over the user skill catalog. Opening the sheet only
/// ever runs `scan()` and `existingSnapshot()`; snapshot builds happen solely
/// through the explicit Rescan action.
@MainActor
final class UserSkillsManagementModel: ObservableObject {
    @Published private(set) var catalogState: UserSkillCatalogState?
    /// `pluginContentDigest` of the newest verified `toastty-user` snapshot,
    /// nil when no verified snapshot exists.
    @Published private(set) var snapshotDigest: String?
    @Published private(set) var userSkillsDirectoryExists = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    let userSkillsDirectoryPath: String

    private let scanProvider: @Sendable () -> UserSkillCatalogState
    private let existingSnapshotProvider: @Sendable () -> UserSkillPluginSnapshot?
    private let refreshProvider: @Sendable () throws -> UserSkillPluginSnapshot?
    private let revealFolder: @MainActor (URL) -> Void
    private let fileManager: FileManager
    private var task: Task<Void, Never>?

    convenience init(
        catalog: ToasttyUserSkillCatalog,
        revealFolder: (@MainActor (URL) -> Void)? = nil
    ) {
        self.init(
            userSkillsDirectoryURL: catalog.userSkillsDirectoryURL,
            scanProvider: { catalog.scan() },
            existingSnapshotProvider: { catalog.existingSnapshot() },
            refreshProvider: { try catalog.refreshUserSkills() },
            revealFolder: revealFolder
        )
    }

    init(
        userSkillsDirectoryURL: URL,
        scanProvider: @escaping @Sendable () -> UserSkillCatalogState,
        existingSnapshotProvider: @escaping @Sendable () -> UserSkillPluginSnapshot?,
        refreshProvider: @escaping @Sendable () throws -> UserSkillPluginSnapshot?,
        revealFolder: (@MainActor (URL) -> Void)? = nil,
        fileManager: FileManager = .default
    ) {
        userSkillsDirectoryPath = userSkillsDirectoryURL.path
        self.scanProvider = scanProvider
        self.existingSnapshotProvider = existingSnapshotProvider
        self.refreshProvider = refreshProvider
        self.revealFolder = revealFolder ?? { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        self.fileManager = fileManager
    }

    var acceptedCount: Int {
        catalogState?.acceptedPackages.count ?? 0
    }

    var sectionTitle: String {
        guard let catalogState, catalogState.packages.isEmpty == false else {
            return "User Skills"
        }
        return "User Skills — \(acceptedCount) included"
    }

    var userSkillsDirectoryDisplayPath: String {
        NSString(string: userSkillsDirectoryPath).abbreviatingWithTildeInPath
    }

    var showsCreateFolderAffordance: Bool {
        userSkillsDirectoryExists == false
    }

    static func statusDescription(for package: UserSkillPackage) -> String {
        switch package.status {
        case .accepted:
            return "Included"
        case .excluded(let diagnostic):
            return diagnostic.displayMessage
        }
    }

    /// Read-only pass: scan plus a verified read of the newest snapshot.
    func refresh() {
        run(performRefresh: false)
    }

    /// Rescan action: scans, and rebuilds the snapshot only when the accepted
    /// set is non-empty or a previously prepared snapshot already exists.
    func rescan() {
        run(performRefresh: true)
    }

    func openUserSkillsFolder() {
        revealFolder(URL(fileURLWithPath: userSkillsDirectoryPath, isDirectory: true))
    }

    func createUserSkillsFolder() {
        let directoryURL = URL(fileURLWithPath: userSkillsDirectoryPath, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            errorMessage = error.localizedDescription
        }
        updateDirectoryExists()
        guard userSkillsDirectoryExists else { return }
        revealFolder(directoryURL)
    }

    /// Awaits the in-flight scan/rescan pass. Test seam.
    func waitForPendingWork() async {
        await task?.value
    }
}

private extension UserSkillsManagementModel {
    struct PassOutcome: Sendable {
        let state: UserSkillCatalogState
        let snapshotDigest: String?
        let refreshError: String?
    }

    func run(performRefresh: Bool) {
        task?.cancel()
        isWorking = true
        if performRefresh {
            errorMessage = nil
        }
        updateDirectoryExists()
        let scan = scanProvider
        let existingSnapshot = existingSnapshotProvider
        let refreshUserSkills = refreshProvider
        task = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> PassOutcome in
                var refreshError: String?
                if performRefresh {
                    let gateState = scan()
                    if gateState.acceptedPackages.isEmpty == false || existingSnapshot() != nil {
                        do {
                            _ = try refreshUserSkills()
                        } catch {
                            refreshError = error.localizedDescription
                        }
                    }
                }
                return PassOutcome(
                    state: scan(),
                    snapshotDigest: existingSnapshot()?.pluginContentDigest,
                    refreshError: refreshError
                )
            }.value
            guard let self, Task.isCancelled == false else { return }
            catalogState = outcome.state
            snapshotDigest = outcome.snapshotDigest
            if performRefresh {
                errorMessage = outcome.refreshError
            }
            isWorking = false
        }
    }

    func updateDirectoryExists() {
        var isDirectory: ObjCBool = false
        userSkillsDirectoryExists = fileManager.fileExists(
            atPath: userSkillsDirectoryPath,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }
}

private extension CodexSkillsManagementModel {
    typealias Operation = @Sendable (
        CodexSkillsManager,
        CodexIntegrationRuntime
    ) throws -> CodexSkillsStatus

    enum OperationResult: Sendable {
        case success(CodexSkillsStatus)
        case codexNotFound(String)
        case failure(String)
    }

    func runOperation(
        refreshProcessPath: Bool = false,
        _ operation: @escaping Operation
    ) {
        task?.cancel()
        isWorking = true
        errorMessage = nil
        codexNotFoundMessage = nil
        let selectedProcessPathProvider = refreshProcessPath
            ? processPathRefreshProvider
            : processPathProvider
        task = Task { [manager] in
            let result: OperationResult = await Task.detached(
                priority: .userInitiated
            ) {
                do {
                    let runtime = try CodexIntegrationRuntimeLocator.resolve(
                        preferredProcessPath: selectedProcessPathProvider()
                    )
                    return OperationResult.success(try operation(manager, runtime))
                } catch let error as CodexPluginCLIError {
                    if case .executableUnavailable = error {
                        return .codexNotFound(
                            "Toastty couldn't find Codex in your login-shell or app PATH. Install Codex or reload configuration after updating your shell."
                        )
                    }
                    return .failure(error.localizedDescription)
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value
            guard Task.isCancelled == false else { return }
            isWorking = false
            switch result {
            case .success(let status):
                self.status = status
            case .codexNotFound(let message):
                status = nil
                codexNotFoundMessage = message
            case .failure(let message):
                status = nil
                errorMessage = message
            }
        }
    }
}
