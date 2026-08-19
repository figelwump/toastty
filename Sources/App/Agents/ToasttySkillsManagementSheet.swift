import RemoteProtocol
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
            deliveryCard
            skillsList
            userSkillsSection
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 620)
        .frame(minHeight: 560)
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
                Text("Toastty provides its four built-in skills, plus your user-created skills, to managed Codex, Claude Code, Pi, OpenCode, and MiMo Code sessions. Ordinary sessions are unaffected.")
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

    /// One compact card for every delivery target: a header with the shared
    /// bundled version, one row per runtime path, and prose only for degraded
    /// states. Codex-specific plugin details and Repair live in the Codex
    /// row's disclosure instead of separate sections at the bottom.
    private var deliveryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            deliveryHeader
            rowDivider
            codexRow
            if detailsExpanded {
                codexDetails
            }
            rowDivider
            launchProvidedRow
        }
        .background(ToastyTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(ToastyTheme.hairline, lineWidth: 1)
        }
        .accessibilityIdentifier("sheet.toastty-skills.status")
    }

    private var deliveryHeader: some View {
        HStack(spacing: 8) {
            Text("Skill Delivery")
                .font(.system(size: 13, weight: .semibold))
            if let version = deliveredSkillsVersion {
                Text(version)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(ToastyTheme.subtleBorder, lineWidth: 1)
                    }
                    .help("Toastty skills version delivered to managed sessions")
            }
            Spacer()
            if model.isWorking || claudeModel.isWorking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    model.refresh(
                        hasActiveManagedCodexSession: hasActiveManagedCodexSession,
                        refreshProcessPath: true
                    )
                    claudeModel.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(ToastyTheme.inactiveText)
                .help("Recheck skills delivery status")
                .accessibilityLabel("Recheck skills delivery status")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(ToastyTheme.hairline)
            .frame(height: 1)
    }

    private var codexRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                detailsExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: statusSymbolName)
                        .foregroundStyle(statusColor)
                    Text("Codex")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    statusPill(statusTitle, color: statusColor)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ToastyTheme.inactiveText)
                        .rotationEffect(.degrees(detailsExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show Codex plugin details and maintenance")
            .accessibilityIdentifier("sheet.codex-skills.details-toggle")

            if let status = model.status, status.isReady == false {
                Text(status.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(ToastyTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheet.codex-skills.status")
    }

    private var codexDetails: some View {
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

            HStack(alignment: .firstTextBaseline) {
                if hasActiveManagedCodexSession {
                    Text("Running sessions pick up repairs after restart.")
                        .font(.system(size: 11))
                        .foregroundStyle(ToastyTheme.inactiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Repair") {
                    model.repair()
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("sheet.codex-skills.repair")
            }
            .padding(.top, 2)
        }
        .font(.system(size: 12))
        .padding(.leading, 36)
        .padding(.trailing, 14)
        .padding(.bottom, 12)
        .accessibilityIdentifier("sheet.codex-skills.details")
    }

    /// Claude Code, Pi, OpenCode, and MiMo Code all consume the same staged
    /// skills tree, so one row reports the shared `claudeModel` status.
    private var launchProvidedRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: claudeStatusSymbolName)
                    .foregroundStyle(claudeStatusColor)
                Text("Claude Code · Pi · OpenCode · MiMo Code")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                statusPill(claudeStatusTitle, color: claudeStatusColor)
            }

            if case .unavailable(let detail) = claudeModel.status {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(ToastyTheme.sessionErrorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheet.launch-provided-skills.status")
    }

    private var skillsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Built-in Skills")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)

                ForEach(ToasttyAgentPluginBundle.skills, id: \.name) { skill in
                    rowDivider
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        (Text("toastty:").foregroundStyle(ToastyTheme.subtleText)
                            + Text(skill.name))
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .frame(width: 210, alignment: .leading)
                        Text(skill.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(ToastyTheme.inactiveText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sheet.toastty-skills.skill.\(skill.name)")
                }
            }
            .background(ToastyTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(ToastyTheme.hairline, lineWidth: 1)
            }

            Text(Self.duplicateSkillsGuidanceText)
                .font(.system(size: 11))
                .foregroundStyle(ToastyTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }

    private var userSkillsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(userSkillsModel.sectionTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if userSkillsModel.isWorking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button {
                                userSkillsModel.rescan()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(ToastyTheme.inactiveText)
                            .help("Rescan user skills")
                            .accessibilityLabel("Rescan user skills")
                            .accessibilityIdentifier("sheet.toastty-skills.user.rescan")
                        }
                        if userSkillsModel.showsCreateFolderAffordance {
                            Button("Create Skills Folder") {
                                userSkillsModel.createUserSkillsFolder()
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("sheet.toastty-skills.user.create-folder")
                        } else {
                            Button {
                                userSkillsModel.openUserSkillsFolder()
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(ToastyTheme.inactiveText)
                            .help("Open \(userSkillsModel.userSkillsDirectoryDisplayPath) in Finder")
                            .accessibilityLabel("Open User Skills Folder")
                            .accessibilityIdentifier("sheet.toastty-skills.user.open-folder")
                        }
                    }
                    Text("Put custom Toastty skills in \(userSkillsModel.userSkillsDirectoryDisplayPath) and they load automatically into new agent sessions.")
                        .font(.system(size: 11))
                        .foregroundStyle(ToastyTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                if let catalogState = userSkillsModel.catalogState, catalogState.packages.isEmpty == false {
                    ForEach(catalogState.packages, id: \.name) { package in
                        rowDivider
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(package.name)
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                .frame(width: 210, alignment: .leading)
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Image(systemName: package.isAccepted
                                    ? "checkmark.circle.fill"
                                    : "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(package.isAccepted
                                        ? ToastyTheme.sessionReadyText
                                        : ToastyTheme.sessionNeedsApprovalText)
                                Text(UserSkillsManagementModel.statusDescription(for: package))
                                    .font(.system(size: 12))
                                    .foregroundStyle(
                                        package.isAccepted
                                            ? ToastyTheme.inactiveText
                                            : ToastyTheme.sessionNeedsApprovalText
                                    )
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("sheet.toastty-skills.user.\(package.name)")
                    }
                } else {
                    rowDivider
                    Text("No user skills found. Add a skill as <name>/SKILL.md with name and description frontmatter.")
                        .font(.system(size: 12))
                        .foregroundStyle(ToastyTheme.inactiveText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }

                if let errorMessage = userSkillsModel.errorMessage {
                    rowDivider
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(ToastyTheme.sessionErrorText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
            .background(ToastyTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(ToastyTheme.hairline, lineWidth: 1)
            }

            Text("Running sessions keep the skills they launched with; new launches use the current set.")
                .font(.system(size: 11))
                .foregroundStyle(ToastyTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheet.toastty-skills.user")
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
        Self.launchDeliveryStatusTitle(for: claudeModel.status)
    }

    private var deliveredSkillsVersion: String? {
        Self.deliveredSkillsVersion(
            claudeStatus: claudeModel.status,
            codexStatus: model.status
        )
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

    /// Static for testability.
    static func launchDeliveryStatusTitle(for status: ClaudeSkillsDeliveryStatus?) -> String {
        switch status {
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

    /// Every runtime delivers the same bundled payload, so the header shows a
    /// single version: the staged skills version when known, otherwise the
    /// Codex plugin's bundled version while the staged check runs.
    static func deliveredSkillsVersion(
        claudeStatus: ClaudeSkillsDeliveryStatus?,
        codexStatus: CodexSkillsStatus?
    ) -> String? {
        switch claudeStatus {
        case .providedAtLaunch(let configuration):
            return configuration.version
        case .stagesOnNextLaunch(let version):
            return version
        case .unavailable, nil:
            return codexStatus?.bundledVersion
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
        Self.title(for: notice.agent)
    }

    private var message: String {
        Self.message(for: notice)
    }

    static func title(for agent: AgentKind) -> String {
        "Toastty skills are now available in \(agent.displayName)"
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

struct ManagedCodexSkillsUnavailableBanner: View {
    let notice: ManagedCodexSkillsUnavailableNotice
    let manage: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ToastyTheme.sessionNeedsApprovalText)
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Codex launched without Toastty skills")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ToastyTheme.primaryText)
                Text(notice.detail)
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
        .background(ToastyTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(ToastyTheme.sessionNeedsApprovalText.opacity(0.65), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.48), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("banner.managed-codex-skills-unavailable")
    }
}
