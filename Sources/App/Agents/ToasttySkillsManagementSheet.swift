import AppKit
import CoreState
import Foundation
import SwiftUI

struct ManagedAgentSkillsProvisionedNotice: Equatable, Sendable {
    let windowID: UUID
    let agent: AgentKind
    let shippedSkillCount: Int
    /// Number of user skill packages delivered with this launch; 0 when the
    /// launch went shipped-only.
    let deliveredUserSkillCount: Int
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

    var showsCreateFolderAffordance: Bool {
        userSkillsDirectoryExists == false
    }

    var codexDeliveryDetail: String {
        if let errorMessage { return errorMessage }
        if let snapshotDigest {
            return "Ready for next launch — digest \(String(snapshotDigest.prefix(8)))"
        }
        return "No user skills are staged for delivery."
    }

    var claudeDeliveryDetail: String {
        snapshotDigest == nil
            ? "No user skills are staged for delivery."
            : "Delivered on next launch"
    }

    /// Pi, OpenCode, and MiMo Code consume the same verified user-skills
    /// snapshot Claude Code does, so their delivery detail mirrors it.
    var otherRuntimesDeliveryDetail: String {
        claudeDeliveryDetail
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

struct ToasttySkillsManagementSheet: View {
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    @StateObject private var model: CodexSkillsManagementModel
    @StateObject private var claudeModel: ClaudeSkillsManagementModel
    @StateObject private var userSkillsModel: UserSkillsManagementModel
    @State private var detailsExpanded = false
    @Environment(\.dismiss) private var dismiss

    init(
        sessionRuntimeStore: SessionRuntimeStore,
        codexSkillsManager: CodexSkillsManager? = nil,
        claudeSkillsBundleManager: (any ClaudeSkillsBundleManaging)? = nil,
        userSkillCatalog: ToasttyUserSkillCatalog? = nil,
        processPathProvider: @escaping @Sendable () -> String? = { nil },
        processPathRefreshProvider: (@Sendable () -> String?)? = nil,
        model: CodexSkillsManagementModel? = nil,
        claudeModel: ClaudeSkillsManagementModel? = nil,
        userSkillsModel: UserSkillsManagementModel? = nil
    ) {
        self.sessionRuntimeStore = sessionRuntimeStore
        _model = StateObject(
            wrappedValue: model ?? CodexSkillsManagementModel(
                manager: codexSkillsManager ?? CodexSkillsManager(),
                processPathProvider: processPathProvider,
                processPathRefreshProvider: processPathRefreshProvider
            )
        )
        _claudeModel = StateObject(
            wrappedValue: claudeModel ?? ClaudeSkillsManagementModel(
                manager: claudeSkillsBundleManager ?? ClaudeSkillsBundleManager()
            )
        )
        _userSkillsModel = StateObject(
            wrappedValue: userSkillsModel ?? UserSkillsManagementModel(
                catalog: userSkillCatalog ?? ToasttyUserSkillCatalog()
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            statusCards
            skillsList
            userSkillsSection
            details
            Spacer(minLength: 0)
            actionBar
        }
        .padding(24)
        .frame(width: 620)
        .frame(minHeight: 650)
        .background(ToastyTheme.chromeBackground)
        .foregroundStyle(ToastyTheme.primaryText)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.isWorking)
        .onAppear {
            model.refresh(hasActiveManagedCodexSession: hasActiveManagedCodexSession)
            claudeModel.refresh()
            userSkillsModel.refresh()
        }
        .onChange(of: activeManagedCodexSessionCount) { _, _ in
            guard model.isWorking == false else { return }
            model.refresh(hasActiveManagedCodexSession: hasActiveManagedCodexSession)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Toastty Skills")
                    .font(.system(size: 20, weight: .semibold))
                Text("Toastty provides its four shipped skills, plus your user-created skills, to managed Codex, Claude Code, Pi, OpenCode, and MiMo Code sessions. Ordinary sessions are unaffected.")
                    .font(.system(size: 12))
                    .foregroundStyle(ToastyTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isWorking)
        }
    }

    private var statusCards: some View {
        VStack(spacing: 12) {
            codexStatusCard
            claudeStatusCard
            otherRuntimesStatusCard
        }
    }

    private var codexStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbolName)
                    .foregroundStyle(statusColor)
                Text("Codex")
                    .font(.system(size: 13, weight: .semibold))
                statusPill(statusTitle, color: statusColor)
                Spacer()
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        model.refresh(
                            hasActiveManagedCodexSession: hasActiveManagedCodexSession,
                            refreshProcessPath: true
                        )
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .help("Recheck Codex skills status")
                    .accessibilityLabel("Recheck Codex skills status")
                }
            }

            if let status = model.status {
                Text(status.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(ToastyTheme.mutedText)
                if let installedVersion = status.installedVersion {
                    Text("Installed version \(installedVersion)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ToastyTheme.inactiveText)
                }
            } else if model.isWorking {
                Text("Checking the managed Codex plugin.")
                    .font(.system(size: 12))
                    .foregroundStyle(ToastyTheme.mutedText)
            }

            if let codexNotFoundMessage = model.codexNotFoundMessage {
                Text(codexNotFoundMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(ToastyTheme.sessionErrorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(ToastyTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(ToastyTheme.hairline, lineWidth: 1)
        }
        .accessibilityIdentifier("sheet.toastty-skills.status")
    }

    private var claudeStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: claudeStatusSymbolName)
                    .foregroundStyle(claudeStatusColor)
                Text("Claude Code")
                    .font(.system(size: 13, weight: .semibold))
                statusPill(claudeStatusTitle, color: claudeStatusColor)
                Spacer()
                if claudeModel.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(claudeStatusDetail)
                .font(.system(size: 12))
                .foregroundStyle(
                    claudeStatusIsUnavailable
                        ? ToastyTheme.sessionErrorText
                        : ToastyTheme.mutedText
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(ToastyTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(ToastyTheme.hairline, lineWidth: 1)
        }
        .accessibilityIdentifier("sheet.claude-skills.status")
    }

    /// Pi, OpenCode, and MiMo Code consume the same staged skills tree Claude
    /// Code does, so this card reuses `claudeModel`'s status rather than
    /// running a second fetch against the shared bundle manager.
    private var otherRuntimesStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: claudeStatusSymbolName)
                    .foregroundStyle(claudeStatusColor)
                Text("Pi, OpenCode, MiMo Code")
                    .font(.system(size: 13, weight: .semibold))
                statusPill(claudeStatusTitle, color: claudeStatusColor)
                Spacer()
                if claudeModel.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(otherRuntimesStatusDetail)
                .font(.system(size: 12))
                .foregroundStyle(
                    claudeStatusIsUnavailable
                        ? ToastyTheme.sessionErrorText
                        : ToastyTheme.mutedText
                )
                .fixedSize(horizontal: false, vertical: true)

            Text("Pi adds skills per launch with --skill; OpenCode and MiMo Code add them through per-launch config content.")
                .font(.system(size: 11))
                .foregroundStyle(ToastyTheme.inactiveText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(ToastyTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(ToastyTheme.hairline, lineWidth: 1)
        }
        .accessibilityIdentifier("sheet.other-runtimes-skills.status")
    }

    private var skillsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shipped Skills")
                .font(.system(size: 13, weight: .semibold))
            ForEach(ToasttyAgentPluginBundle.skills, id: \.name) { skill in
                VStack(alignment: .leading, spacing: 3) {
                    Text("toastty:\(skill.name)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Text(skill.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(ToastyTheme.mutedText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sheet.toastty-skills.skill.\(skill.name)")
            }

            Text(Self.duplicateSkillsGuidanceText)
                .font(.system(size: 11))
                .foregroundStyle(ToastyTheme.inactiveText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private var userSkillsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(userSkillsModel.sectionTitle)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if userSkillsModel.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Rescan") {
                    userSkillsModel.rescan()
                }
                .disabled(userSkillsModel.isWorking)
                .accessibilityIdentifier("sheet.toastty-skills.user.rescan")
                if userSkillsModel.showsCreateFolderAffordance {
                    Button("Create Skills Folder") {
                        userSkillsModel.createUserSkillsFolder()
                    }
                    .accessibilityIdentifier("sheet.toastty-skills.user.create-folder")
                } else {
                    Button("Open User Skills Folder") {
                        userSkillsModel.openUserSkillsFolder()
                    }
                    .accessibilityIdentifier("sheet.toastty-skills.user.open-folder")
                }
            }

            if let catalogState = userSkillsModel.catalogState, catalogState.packages.isEmpty == false {
                ForEach(catalogState.packages, id: \.name) { package in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(package.name)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        Text(UserSkillsManagementModel.statusDescription(for: package))
                            .font(.system(size: 12))
                            .foregroundStyle(
                                package.isAccepted
                                    ? ToastyTheme.mutedText
                                    : ToastyTheme.sessionNeedsApprovalText
                            )
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sheet.toastty-skills.user.\(package.name)")
                }
            } else {
                Text("No user skills found. Add a skill as \(userSkillsModel.userSkillsDirectoryPath)/<name>/SKILL.md with name and description frontmatter.")
                    .font(.system(size: 12))
                    .foregroundStyle(ToastyTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex: \(userSkillsModel.codexDeliveryDetail)")
                Text("Claude Code: \(userSkillsModel.claudeDeliveryDetail)")
                Text("Pi, OpenCode, MiMo Code: \(userSkillsModel.otherRuntimesDeliveryDetail)")
                Text("Running sessions keep the skills they launched with; new launches use the current set.")
            }
            .font(.system(size: 11))
            .foregroundStyle(ToastyTheme.inactiveText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheet.toastty-skills.user")
    }

    private var details: some View {
        DisclosureGroup("Codex plugin details", isExpanded: $detailsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let status = model.status {
                    technicalRow("Managed profile", value: status.profileConfigPath)
                    technicalRow("Plugin cache", value: status.cachePath ?? "Not installed")
                    technicalRow("Bundled version", value: status.bundledVersion ?? "Unavailable")
                    technicalRow("Bundled digest", value: status.bundledDigest ?? "Unavailable")
                    technicalRow("Installed version", value: status.installedVersion ?? "Not installed")
                    technicalRow("Installed digest", value: status.installedDigest ?? "Not installed")
                } else if model.codexNotFoundMessage != nil {
                    Text("Codex paths are unavailable because Toastty could not find a supported codex or cdx executable.")
                        .foregroundStyle(ToastyTheme.mutedText)
                } else {
                    Text("Details are available after the status check completes.")
                        .foregroundStyle(ToastyTheme.mutedText)
                }
            }
            .padding(.top, 8)
        }
        .font(.system(size: 12))
        .accessibilityIdentifier("sheet.codex-skills.details")
    }

    private var actionBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex plugin maintenance")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ToastyTheme.mutedText)
                if hasActiveManagedCodexSession {
                    Text("Running sessions pick up repairs after restart.")
                        .font(.system(size: 11))
                        .foregroundStyle(ToastyTheme.inactiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Repair") {
                model.repair()
            }
            .disabled(model.isWorking)
            .accessibilityIdentifier("sheet.codex-skills.repair")
        }
    }

    @ViewBuilder
    private func statusPill(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(color.opacity(0.3), lineWidth: 1)
            }
    }

    @ViewBuilder
    private func technicalRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .fontWeight(.semibold)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(ToastyTheme.inactiveText)
                .textSelection(.enabled)
        }
    }

    private var activeManagedCodexSessionCount: Int {
        sessionRuntimeStore.sessionRegistry.sessionsByID.values.filter {
            $0.isActive && $0.agent == .codex
        }.count
    }

    private var hasActiveManagedCodexSession: Bool {
        activeManagedCodexSessionCount > 0
    }

    private var statusTitle: String {
        switch model.status?.availability {
        case .ready: return model.status?.updatePending == true ? "Update pending" : "Ready"
        case .notInstalled: return "Not installed"
        case .unrunnable: return "Codex can't run"
        case .failed: return "Needs attention"
        case .unsupported: return "Unsupported Codex version"
        case nil:
            if model.codexNotFoundMessage != nil { return "Codex not found" }
            return model.errorMessage == nil ? "Checking status" : "Status unavailable"
        }
    }

    private var statusSymbolName: String {
        switch model.status?.availability {
        case .ready: return model.status?.updatePending == true ? "clock.badge.exclamationmark" : "checkmark.circle.fill"
        case .notInstalled: return "arrow.down.circle"
        case .unrunnable, .unsupported: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case nil:
            if model.codexNotFoundMessage != nil { return "questionmark.circle" }
            return model.errorMessage == nil ? "ellipsis.circle" : "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch model.status?.availability {
        case .ready: return model.status?.updatePending == true
            ? ToastyTheme.sessionNeedsApprovalText
            : ToastyTheme.sessionReadyText
        case .notInstalled: return ToastyTheme.inactiveText
        case .unrunnable, .unsupported: return ToastyTheme.sessionNeedsApprovalText
        case .failed: return ToastyTheme.sessionErrorText
        case nil:
            if model.codexNotFoundMessage != nil { return ToastyTheme.inactiveText }
            return model.errorMessage == nil ? ToastyTheme.inactiveText : ToastyTheme.sessionErrorText
        }
    }

    private var claudeStatusTitle: String {
        switch claudeModel.status {
        case .providedAtLaunch:
            return "Provided at launch"
        case .stagesOnNextLaunch:
            return "Stages on next launch"
        case .unavailable:
            return "Needs attention"
        case nil:
            return "Checking"
        }
    }

    private var claudeStatusDetail: String {
        switch claudeModel.status {
        case .providedAtLaunch(let configuration):
            return "Toastty passes version \(configuration.version) only to managed Claude Code launches."
        case .stagesOnNextLaunch(let version):
            return "Toastty will stage version \(version) when the next managed Claude Code session launches."
        case .unavailable(let detail):
            return detail
        case nil:
            return "Checking Toastty's bundled Claude Code skills."
        }
    }

    private var claudeStatusSymbolName: String {
        switch claudeModel.status {
        case .providedAtLaunch:
            return "checkmark.circle.fill"
        case .stagesOnNextLaunch:
            return "arrow.right.circle.fill"
        case .unavailable:
            return "xmark.circle.fill"
        case nil:
            return "ellipsis.circle"
        }
    }

    private var claudeStatusColor: Color {
        switch claudeModel.status {
        case .providedAtLaunch:
            return ToastyTheme.sessionReadyText
        case .stagesOnNextLaunch:
            return ToastyTheme.accent
        case .unavailable:
            return ToastyTheme.sessionErrorText
        case nil:
            return ToastyTheme.inactiveText
        }
    }

    private var claudeStatusIsUnavailable: Bool {
        guard case .unavailable = claudeModel.status else { return false }
        return true
    }

    private var otherRuntimesStatusDetail: String {
        Self.otherRuntimesStatusDetail(for: claudeModel.status)
    }

    /// Static for testability, matching `ManagedAgentSkillsProvisionedBanner.message(for:)`.
    static func otherRuntimesStatusDetail(for status: ClaudeSkillsDeliveryStatus?) -> String {
        switch status {
        case .providedAtLaunch(let configuration):
            return "Toastty passes version \(configuration.version) only to managed Pi, OpenCode, and MiMo Code launches."
        case .stagesOnNextLaunch(let version):
            return "Toastty will stage version \(version) when the next managed Pi, OpenCode, or MiMo Code session launches."
        case .unavailable(let detail):
            return detail
        case nil:
            return "Checking Toastty's bundled skills for Pi, OpenCode, and MiMo Code."
        }
    }

    static let duplicateSkillsGuidanceText = "Toastty never changes global skill folders. If duplicate Toastty skills appear, remove the separately installed copies from ~/.codex/skills, ~/.claude/skills, or ~/.agents/skills."
}

struct ManagedAgentSkillsProvisionedBanner: View {
    let notice: ManagedAgentSkillsProvisionedNotice
    let manage: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(ToastyTheme.accent.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ToastyTheme.accent)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ToastyTheme.primaryText)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button("View Skills…", action: manage)
                .buttonStyle(.borderedProminent)
                .tint(ToastyTheme.accent)
                .foregroundStyle(ToastyTheme.accentDark)
                .controlSize(.small)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ToastyTheme.inactiveText)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(ToastyTheme.elevatedBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(ToastyTheme.sessionReadyBackground)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(ToastyTheme.accent.opacity(0.55), lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(ToastyTheme.accent)
                .frame(width: 4)
                .padding(.vertical, 9)
        }
        .shadow(color: .black.opacity(0.48), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("banner.managed-agent-skills-provisioned")
    }

    private var title: String {
        switch notice.agent {
        case .codex: "Codex skills are ready"
        case .claude: "Claude Code skills are ready"
        default: "Toastty skills are ready"
        }
    }

    private var message: String {
        Self.message(for: notice)
    }

    static func message(for notice: ManagedAgentSkillsProvisionedNotice) -> String {
        let totalCount = notice.shippedSkillCount + notice.deliveredUserSkillCount
        var text = "Toastty enabled \(totalCount) skill\(totalCount == 1 ? "" : "s") for managed \(notice.agent.displayName) sessions"
        if notice.deliveredUserSkillCount > 0 {
            text += " (including \(notice.deliveredUserSkillCount) user skill\(notice.deliveredUserSkillCount == 1 ? "" : "s"))"
        }
        text += ". Global and project skill folders were not changed."
        return text
    }
}
