import CoreState
import SwiftUI

/// What the sidebar needs to list remote hosts and open their sessions.
/// Passed through the environment so views that host a sidebar without
/// remote hosts, such as tests, need no extra arguments.
@MainActor
struct RemoteHostsSidebarContext {
    let hostsStore: RemoteHostsStore
    let opener: RemoteHostTerminalOpener
}

private struct RemoteHostsSidebarContextKey: EnvironmentKey {
    static let defaultValue: RemoteHostsSidebarContext? = nil
}

extension EnvironmentValues {
    var remoteHostsSidebarContext: RemoteHostsSidebarContext? {
        get { self[RemoteHostsSidebarContextKey.self] }
        set { self[RemoteHostsSidebarContextKey.self] = newValue }
    }
}

/// One group per remote host from `remotes.toml`, below the local workspaces.
struct SidebarRemoteHostsSection: View {
    let windowID: UUID
    @ObservedObject var hostsStore: RemoteHostsStore
    let opener: RemoteHostTerminalOpener

    @State private var collapsedRemoteIDs: Set<String> = []
    @State private var pairingRemote: RemoteHostConfiguration?
    @State private var noticeByRemoteID: [String: String] = [:]
    @State private var hoveredSessionID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hostsStore.hosts) { host in
                hostGroup(host)
            }
        }
        .sheet(item: $pairingRemote) { configuration in
            RemoteHostPairingSheet(configuration: configuration, hostsStore: hostsStore)
        }
    }

    private func hostGroup(_ host: RemoteHostState) -> some View {
        let presentation = RemoteHostSidebarPresentation(host: host)
        let isExpanded = collapsedRemoteIDs.contains(host.id) == false
        return VStack(alignment: .leading, spacing: 0) {
            header(host, presentation: presentation, isExpanded: isExpanded)
            if let notice = noticeByRemoteID[host.id] {
                Text(notice)
                    .font(ToastyTheme.fontWorkspaceSessionDetail)
                    .foregroundStyle(ToastyTheme.sessionErrorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .background {
                        SidebarSemanticTextBridge(text: notice)
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                    }
            }
            if isExpanded {
                if presentation.workspaces.isEmpty {
                    if let emptyText = emptyText(host, presentation: presentation) {
                        Text(emptyText)
                            .font(ToastyTheme.fontWorkspaceSessionDetail)
                            .foregroundStyle(ToastyTheme.sidebarChildContextText)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    }
                } else {
                    ForEach(presentation.workspaces) { workspace in
                        workspaceRows(workspace, host: host)
                    }
                }
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(ToastyTheme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.remote.\(host.id)")
    }

    private func emptyText(_ host: RemoteHostState, presentation: RemoteHostSidebarPresentation) -> String? {
        switch host.status {
        case .live: "No agent sessions"
        case .notPaired: "Pair to list this Mac's sessions."
        default: nil
        }
    }

    private func header(
        _ host: RemoteHostState,
        presentation: RemoteHostSidebarPresentation,
        isExpanded: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                if isExpanded {
                    collapsedRemoteIDs.insert(host.id)
                } else {
                    collapsedRemoteIDs.remove(host.id)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 9)
                    Text(host.configuration.displayName.uppercased())
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .lineLimit(1)
                    if presentation.isLive {
                        Circle()
                            .fill(ToastyTheme.sessionReadyText)
                            .frame(width: 5, height: 5)
                    }
                    if let statusLabel = presentation.statusLabel {
                        Text(statusLabel)
                            .font(ToastyTheme.fontWorkspaceAgentCount)
                            .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(ToastyTheme.sidebarChildContextText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headerAccessibilityLabel(host, presentation: presentation))
            .background {
                SidebarSemanticTextBridge(text: headerAccessibilityLabel(host, presentation: presentation))
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }

            Spacer(minLength: 0)

            if presentation.offersPairing {
                Button("Pair…") { pairingRemote = host.configuration }
                    .buttonStyle(.plain)
                    .font(ToastyTheme.fontWorkspaceSessionChip)
                    .foregroundStyle(ToastyTheme.accent)
                    .accessibilityIdentifier("sidebar.remote.\(host.id).pair")
            }

            Menu {
                if host.status == .notPaired {
                    Button("Pair…") { pairingRemote = host.configuration }
                } else {
                    Button("Reconnect") { hostsStore.reconnect(remoteID: host.id) }
                    Button("Pair Again…") { pairingRemote = host.configuration }
                    Button("Unpair") { unpair(host) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ToastyTheme.sidebarChildContextText)
                    .frame(width: 16, height: 14)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(host.configuration.displayName) remote options")
        }
        .frame(minHeight: 16)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func headerAccessibilityLabel(
        _ host: RemoteHostState,
        presentation: RemoteHostSidebarPresentation
    ) -> String {
        let status = presentation.statusLabel ?? "connected"
        return "Remote \(host.configuration.displayName), \(status), \(presentation.sessionCount) sessions"
    }

    private func workspaceRows(
        _ workspace: RemoteHostSidebarPresentation.Workspace,
        host: RemoteHostState
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                if workspace.isSubspace {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(ToastyTheme.sidebarChildContextText)
                }
                Text(workspace.title)
                    .font(ToastyTheme.fontWorkspaceNameInactive)
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .lineLimit(1)
            }
            .padding(.leading, workspace.isSubspace ? 22 : 10)
            .padding(.trailing, 10)
            .padding(.vertical, 4)

            ForEach(workspace.sessions) { session in
                sessionRow(session, host: host, indent: workspace.isSubspace ? 34 : 22)
            }
        }
        .padding(.bottom, 6)
    }

    private func sessionRow(
        _ session: RemoteHostSidebarPresentation.Session,
        host: RemoteHostState,
        indent: CGFloat
    ) -> some View {
        Button {
            open(session, host: host)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(ToastyTheme.fontWorkspaceSessionAgent)
                        .foregroundStyle(
                            session.canAttach ? ToastyTheme.sidebarSessionAgentText : ToastyTheme.sidebarChildContextText
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    statusView(for: session.statusKind)
                }
                Text(session.detail.isEmpty ? session.agentName : "\(session.agentName) · \(session.detail)")
                    .font(ToastyTheme.fontWorkspaceSessionDetail)
                    .foregroundStyle(ToastyTheme.sidebarSummaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, indent)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hoveredSessionID == session.id ? ToastyTheme.sidebarSessionHoverBackground : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering {
                hoveredSessionID = session.id
            } else if hoveredSessionID == session.id {
                hoveredSessionID = nil
            }
        }
        .help(session.attachUnavailableReason ?? "Open a terminal attached to this session on \(host.configuration.displayName)")
        .accessibilityLabel(sessionAccessibilityLabel(session))
        .accessibilityIdentifier("sidebar.remote.\(host.id).session.\(session.id.uuidString)")
        .background {
            SidebarSemanticTextBridge(text: sessionAccessibilityLabel(session))
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    /// The desktop badge has text only for states that need attention. A
    /// working session gets a quiet label instead of an empty badge, and an
    /// idle one gets nothing.
    @ViewBuilder
    private func statusView(for statusKind: SessionStatusKind?) -> some View {
        if let statusKind {
            if SidebarSessionPresentation.sessionStatusBadgeLabel(for: statusKind).isEmpty == false {
                SessionStatusBadge(kind: statusKind)
            } else if statusKind == .working {
                Text("working")
                    .font(ToastyTheme.fontWorkspaceSessionElapsed)
                    .foregroundStyle(ToastyTheme.sidebarChildContextText)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private func sessionAccessibilityLabel(_ session: RemoteHostSidebarPresentation.Session) -> String {
        let status = session.statusKind.map { statusKind in
            let badgeLabel = SidebarSessionPresentation.sessionStatusBadgeLabel(for: statusKind)
            return badgeLabel.isEmpty ? statusKind.rawValue : badgeLabel
        } ?? "status unavailable"
        let attach = session.canAttach ? "opens a terminal" : "no terminal to attach to"
        return "Remote session \(session.title), \(session.agentName), \(status), \(attach)"
    }

    private func unpair(_ host: RemoteHostState) {
        Task {
            switch await hostsStore.unpair(remoteID: host.id) {
            case .success:
                noticeByRemoteID.removeValue(forKey: host.id)
            case .failure(let error):
                noticeByRemoteID[host.id] = error.localizedDescription
            }
        }
    }

    private func open(_ session: RemoteHostSidebarPresentation.Session, host: RemoteHostState) {
        switch opener.open(remoteID: host.id, conversationID: session.id, windowID: windowID) {
        case .success:
            noticeByRemoteID.removeValue(forKey: host.id)
        case .failure(let failure):
            noticeByRemoteID[host.id] = failure.localizedDescription
        }
    }
}

/// Collects the pairing code that the other Mac shows in Remote Access.
struct RemoteHostPairingSheet: View {
    let configuration: RemoteHostConfiguration
    let hostsStore: RemoteHostsStore

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var errorText: String?
    @State private var isPairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair with \(configuration.displayName)")
                .font(.headline)
            Text(
                "On \(configuration.displayName), open Toastty > Remote Access… and choose Show Pairing QR. "
                    + "Enter the fallback code shown beside the QR code. The offer expires after two minutes."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text(configuration.gatewayURL.host ?? configuration.gatewayURL.absoluteString)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            TextField("Fallback code", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disabled(isPairing)
                .onSubmit(pair)
                .accessibilityIdentifier("remote-host.pairing.code")
            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isPairing ? "Pairing…" : "Pair", action: pair)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isPairing || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func pair() {
        guard isPairing == false else { return }
        isPairing = true
        errorText = nil
        Task {
            let result = await hostsStore.pair(remoteID: configuration.id, input: code)
            isPairing = false
            switch result {
            case .success:
                dismiss()
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }
}
