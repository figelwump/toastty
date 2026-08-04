import CoreState
import Foundation
import SwiftUI

struct ManagedAgentSkillsProvisionedNotice: Equatable, Sendable {
    let windowID: UUID
    let agent: AgentKind
}

enum ManagedAgentSkillsProvisionedNoticeStore {
    static func didShowKey(for agent: AgentKind) -> String {
        "toastty.\(agent.rawValue)SkillsProvisionedNoticeDidShow"
    }

    static func claim(
        for windowID: UUID,
        notificationObject: Any?,
        userDefaults: UserDefaults = ToasttyAppDefaults.current
    ) -> AgentKind? {
        guard let notice = notificationObject as? ManagedAgentSkillsProvisionedNotice,
              notice.windowID == windowID,
              userDefaults.bool(forKey: didShowKey(for: notice.agent)) == false else {
            return nil
        }
        userDefaults.set(true, forKey: didShowKey(for: notice.agent))
        return notice.agent
    }
}

@MainActor
final class CodexSkillsManagementModel: ObservableObject {
    @Published private(set) var status: CodexSkillsStatus?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    private let manager: CodexSkillsManager
    private var task: Task<Void, Never>?

    init(manager: CodexSkillsManager = CodexSkillsManager()) {
        self.manager = manager
    }

    func refresh(hasActiveManagedCodexSession: Bool) {
        runOperation { manager in
            let runtime = try CodexIntegrationRuntimeLocator.resolve()
            return manager.status(
                runtime: runtime,
                hasActiveManagedCodexSession: hasActiveManagedCodexSession
            )
        }
    }

    func repair() {
        runOperation { manager in
            let runtime = try CodexIntegrationRuntimeLocator.resolve()
            return try manager.repair(runtime: runtime)
        }
    }

    func uninstall(hasActiveManagedCodexSession: Bool) {
        runOperation { manager in
            let runtime = try CodexIntegrationRuntimeLocator.resolve()
            return try manager.uninstall(
                runtime: runtime,
                hasActiveManagedCodexSession: hasActiveManagedCodexSession
            )
        }
    }
}

private extension CodexSkillsManagementModel {
    typealias Operation = @Sendable (CodexSkillsManager) throws -> CodexSkillsStatus

    func runOperation(_ operation: @escaping Operation) {
        task?.cancel()
        isWorking = true
        errorMessage = nil
        task = Task { [manager] in
            let result: Result<CodexSkillsStatus, AgentGetStartedActionError> = await Task.detached(
                priority: .userInitiated
            ) {
                do {
                    return .success(try operation(manager))
                } catch {
                    return .failure(AgentGetStartedActionError(message: error.localizedDescription))
                }
            }.value
            guard Task.isCancelled == false else { return }
            isWorking = false
            switch result {
            case .success(let status):
                self.status = status
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct CodexSkillsManagementSheet: View {
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    @StateObject private var model: CodexSkillsManagementModel
    @State private var showsUninstallConfirmation = false
    @State private var detailsExpanded = false
    @Environment(\.dismiss) private var dismiss

    init(
        sessionRuntimeStore: SessionRuntimeStore,
        model: @autoclosure @escaping () -> CodexSkillsManagementModel = CodexSkillsManagementModel()
    ) {
        self.sessionRuntimeStore = sessionRuntimeStore
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            statusCard
            hostDetails
            skillsList
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
        .confirmationDialog(
            "Uninstall Toastty Codex Skills?",
            isPresented: $showsUninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                model.uninstall(
                    hasActiveManagedCodexSession: hasActiveManagedCodexSession
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only Toastty's Codex plugin, marketplace registration, and staged plugin files. Codex hooks and unrelated skills are not changed.")
        }
        .onAppear {
            model.refresh(hasActiveManagedCodexSession: hasActiveManagedCodexSession)
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
                Text("Toastty provides the same four namespaced skills to managed Codex and Claude Code sessions.")
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

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbolName)
                    .foregroundStyle(statusColor)
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text("Codex plugin")
                    .font(.system(size: 11))
                    .foregroundStyle(ToastyTheme.inactiveText)
                Spacer()
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
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
        .accessibilityIdentifier("sheet.codex-skills.status")
    }

    private var hostDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Codex: installed as a plugin and enabled only for managed sessions.", systemImage: "terminal")
            Label("Claude Code: staged by Toastty and passed only to the managed session.", systemImage: "terminal.fill")
        }
        .font(.system(size: 12))
        .foregroundStyle(ToastyTheme.mutedText)
    }

    private var skillsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Skills")
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
                .accessibilityIdentifier("sheet.codex-skills.skill.\(skill.name)")
            }

            Text("Toastty does not change separately installed global skills. If duplicate, unnamespaced Toastty skills appear, remove those copies manually from ~/.codex/skills, ~/.claude/skills, or ~/.agents/skills.")
                .font(.system(size: 11))
                .foregroundStyle(ToastyTheme.inactiveText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private var details: some View {
        DisclosureGroup("Details", isExpanded: $detailsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let status = model.status {
                    technicalRow("Marketplace", value: status.marketplacePath)
                    technicalRow("Installed plugin", value: status.installedPath ?? "Not installed")
                    technicalRow("Bundled version", value: status.bundledVersion ?? "Unavailable")
                    technicalRow("Bundled digest", value: status.bundledDigest ?? "Unavailable")
                    if status.disabledNameTombstones.isEmpty == false {
                        technicalRow(
                            "Disabled-name tombstones",
                            value: status.disabledNameTombstones.joined(separator: ", ")
                        )
                    }
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
            if hasActiveManagedCodexSession {
                Text("Uninstall is available after managed Codex sessions stop. Repair applies immediately; running sessions pick up changes after restart.")
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

            Button("Uninstall…", role: .destructive) {
                showsUninstallConfirmation = true
            }
            .disabled(
                model.isWorking
                    || hasActiveManagedCodexSession
                    || model.status?.installedVersion == nil
            )
            .accessibilityIdentifier("sheet.codex-skills.uninstall")
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
        case .failed: return "Needs attention"
        case .unsupported: return "Unsupported Codex version"
        case nil: return model.errorMessage == nil ? "Checking status" : "Status unavailable"
        }
    }

    private var statusSymbolName: String {
        switch model.status?.availability {
        case .ready: return model.status?.updatePending == true ? "clock.badge.exclamationmark" : "checkmark.circle.fill"
        case .notInstalled: return "arrow.down.circle"
        case .failed, .unsupported: return "exclamationmark.triangle.fill"
        case nil: return model.errorMessage == nil ? "ellipsis.circle" : "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch model.status?.availability {
        case .ready: return model.status?.updatePending == true
            ? ToastyTheme.sessionNeedsApprovalText
            : ToastyTheme.sessionReadyText
        case .notInstalled: return ToastyTheme.inactiveText
        case .failed, .unsupported: return ToastyTheme.sessionErrorText
        case nil: return model.errorMessage == nil ? ToastyTheme.inactiveText : ToastyTheme.sessionErrorText
        }
    }
}

struct ManagedAgentSkillsProvisionedBanner: View {
    let agent: AgentKind
    let manage: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(ToastyTheme.accent)
            Text(message)
                .font(.system(size: 12))
            Spacer(minLength: 8)
            Button("View Skills…", action: manage)
                .buttonStyle(.borderless)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ToastyTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(ToastyTheme.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
        .accessibilityIdentifier("banner.managed-agent-skills-provisioned")
    }

    private var message: String {
        switch agent {
        case .codex:
            "Toastty enabled four skills for managed Codex sessions. Your global and project skill folders were not changed."
        case .claude:
            "Toastty enabled four session-only skills for managed Claude Code sessions. Your global and project skill folders were not changed."
        default:
            "Toastty enabled four skills for this managed session. Your global and project skill folders were not changed."
        }
    }
}
