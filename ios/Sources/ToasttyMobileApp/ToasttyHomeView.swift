import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

enum ToasttyWorkspaceSessionFilter: String, CaseIterable {
    case all
    case active

    static let defaultFilter = ToasttyWorkspaceSessionFilter.all
    static let preferenceKey = "toastty-mobile-workspace-session-filter"

    var title: String {
        switch self {
        case .all: "All"
        case .active: "Active"
        }
    }

    func conversations(in workspace: MobileWorkspace) -> [MobileConversation] {
        workspace.sortedConversations.filter { conversation in
            self == .all || conversation.state.bucket != .idle
        }
    }

    func workspaces(from workspaces: [MobileWorkspace]) -> [MobileWorkspace] {
        workspaces.compactMap { workspace in
            let conversations = conversations(in: workspace)
            // All keeps panel-only workspaces so their panels stay reachable.
            // Active lists only workspaces with something happening, so open
            // panels alone no longer keep an idle workspace's header.
            let keepsPanelOnlyWorkspace = self == .all && !workspace.panels.isEmpty
            guard !conversations.isEmpty || keepsPanelOnlyWorkspace else { return nil }
            return MobileWorkspace(
                id: workspace.id,
                title: workspace.title,
                conversations: conversations,
                panels: workspace.panels,
                annotations: workspace.annotations
            )
        }
    }

    /// How many sessions this filter leaves out, so a short Active list says
    /// what it hides instead of looking like a partial snapshot.
    func hiddenSessionCount(in workspaces: [MobileWorkspace]) -> Int {
        guard self == .active else { return 0 }
        return workspaces.reduce(0) { count, workspace in
            count + workspace.conversations.count - conversations(in: workspace).count
        }
    }

    static func hiddenSessionsLabel(count: Int) -> String {
        "\(count) idle \(count == 1 ? "session" : "sessions") hidden"
    }
}

struct ToasttyHomeView: View {
    let controller: HomeScreenController
    let refresh: () async -> Void
    let onSettings: () -> Void

    @AppStorage private var storedWorkspaceSessionFilter: String
    @State private var isRetryingConnection = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        controller: HomeScreenController,
        refresh: @escaping () async -> Void = {},
        onSettings: @escaping () -> Void = {},
        defaults: UserDefaults = .standard
    ) {
        self.controller = controller
        self.refresh = refresh
        self.onSettings = onSettings
        _storedWorkspaceSessionFilter = AppStorage(
            wrappedValue: ToasttyWorkspaceSessionFilter.defaultFilter.rawValue,
            ToasttyWorkspaceSessionFilter.preferenceKey,
            store: defaults
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                workspaceContent
            }
            // Reorders now happen only on status-bucket transitions, so
            // animating them keeps a moving row trackable instead of
            // teleporting.
            .animation(reduceMotion ? nil : .default, value: orderedRowIDs)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            await refresh()
        }
        .scrollIndicators(.hidden)
        // The identifier must precede safeAreaInset: applied after it, it
        // stamps both the scroll view and the inset header, breaking UI-test
        // queries with ambiguous matches.
        .accessibilityIdentifier("toastty-mobile-home")
        .safeAreaInset(edge: .top, spacing: 0) {
            // Connection state and the workspace filter stay visible while
            // sessions scroll underneath them.
            VStack(spacing: 10) {
                header
                connectionNotice
                workspaceSessionFilterPicker
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
            .background(ToasttyDesignTokens.background)
        }
        .background(ToasttyDesignTokens.background)
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.warning, trigger: needsApprovalCount) { old, new in
            new > old
        }
        .onAppear {
            if ToasttyWorkspaceSessionFilter(rawValue: storedWorkspaceSessionFilter) == nil {
                storedWorkspaceSessionFilter =
                    ToasttyWorkspaceSessionFilter.defaultFilter.rawValue
            }
        }
    }

    private var orderedRowIDs: [UUID] {
        visibleWorkspaces.flatMap { workspace in
            [workspace.id] + workspace.conversations.map(\.id)
        }
    }

    private var selectedWorkspaceSessionFilter: ToasttyWorkspaceSessionFilter {
        ToasttyWorkspaceSessionFilter(rawValue: storedWorkspaceSessionFilter) ?? .defaultFilter
    }

    private var workspaceSessionFilterSelection: Binding<ToasttyWorkspaceSessionFilter> {
        Binding(
            get: { selectedWorkspaceSessionFilter },
            set: { storedWorkspaceSessionFilter = $0.rawValue }
        )
    }

    private var workspaceSessionFilterPicker: some View {
        Picker("Workspace sessions", selection: workspaceSessionFilterSelection) {
            ForEach(ToasttyWorkspaceSessionFilter.allCases, id: \.self) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("toastty-mobile-workspace-session-filter")
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if visibleWorkspaces.isEmpty {
            workspaceEmptyState
        } else {
            ForEach(visibleWorkspaces) { workspace in
                Section {
                    ForEach(workspace.conversations) { conversation in
                        ToasttySessionRow(
                            conversation: conversation,
                            freshness: controller.freshness,
                            accessibilityIdentifier:
                                "toastty-mobile-grouped-card-\(conversation.id.uuidString)",
                            onOpen: controller.open
                        )
                    }
                } header: {
                    workspaceHeader(workspace)
                        .padding(.top, 12)
                }
            }
        }
        // Shown under the empty state too, so an all-idle Mac still says how
        // much Active is hiding.
        hiddenSessionsFooter
    }

    @ViewBuilder
    private var hiddenSessionsFooter: some View {
        let count = selectedWorkspaceSessionFilter.hiddenSessionCount(
            in: controller.snapshot.rankedWorkspaces
        )
        if count > 0 {
            Text(ToasttyWorkspaceSessionFilter.hiddenSessionsLabel(count: count))
                .font(.caption2.monospaced())
                .foregroundStyle(ToasttyDesignTokens.mutedText)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
                .accessibilityIdentifier("toastty-mobile-hidden-sessions")
        }
    }

    private var visibleWorkspaces: [MobileWorkspace] {
        selectedWorkspaceSessionFilter.workspaces(from: controller.snapshot.rankedWorkspaces)
    }

    private func workspaceHeader(_ workspace: MobileWorkspace) -> some View {
        NavigationLink(value: ToasttyMobileRoute.workspace(workspace.id)) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.title)
                        .font(.headline)
                        .foregroundStyle(ToasttyDesignTokens.primaryText)
                        .lineLimit(1)
                    if !workspace.annotations.isEmpty {
                        ToasttyWorkspaceHeaderAnnotations(annotations: workspace.annotations)
                            .padding(.top, 3)
                            .padding(.bottom, 2)
                    }
                    Text(sessionCountLabel(workspace.conversations.count))
                        .font(.caption2.monospaced())
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.workspaceHeaderAccessibilityLabel(
            workspace, sessionCount: sessionCountLabel(workspace.conversations.count)
        ))
        .accessibilityHint("Opens the workspace")
        .accessibilityIdentifier("toastty-mobile-workspace-\(workspace.id.uuidString)")
    }

    /// Home chips are display-only, so every chip folds into the header's
    /// label in visual order.
    static func workspaceHeaderAccessibilityLabel(
        _ workspace: MobileWorkspace, sessionCount: String
    ) -> String {
        ([workspace.title]
            + workspace.annotations.map(ToasttyWorkspaceAnnotationAccessibility.label(for:))
            + [sessionCount])
            .joined(separator: ", ")
    }

    private var workspaceEmptyState: some View {
        ContentUnavailableView(
            selectedWorkspaceSessionFilter == .active ? "No active sessions" : "No sessions yet",
            systemImage: "rectangle.stack",
            description: Text(
                selectedWorkspaceSessionFilter == .active
                    ? "Choose All to show idle sessions."
                    : "Open a session in Toastty on your Mac and it will appear here."
            )
        )
        .foregroundStyle(ToasttyDesignTokens.secondaryText)
        .padding(.vertical, 32)
    }

    private var needsApprovalCount: Int {
        controller.snapshot.activitySessions.lazy.filter {
            $0.state.bucket == .needsApproval
        }.count
    }

    private func sessionCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "session" : "sessions")"
    }

    @ViewBuilder
    private var connectionNotice: some View {
        if let message = controller.connectionNoticeMessage {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 9) {
                    connectionNoticeIndicator
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(controller.freshness.accessibilityLabel). \(message)")
                .accessibilityValue(showsProgressIndicator ? "In progress" : "")
                .accessibilityIdentifier("toastty-mobile-connection-notice")

                if controller.freshness == .reconnecting {
                    Button("Retry", action: retryConnection)
                        .buttonStyle(.bordered)
                        .frame(minWidth: 44, minHeight: 44)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .disabled(isRetryingConnection)
                        .accessibilityLabel("Retry connection")
                        .accessibilityIdentifier("toastty-mobile-connection-retry")
                }
            }
            .font(.caption)
            .foregroundStyle(controller.freshness == .unreachable
                ? ToasttyDesignTokens.red
                : ToasttyDesignTokens.amberText)
            .toasttyCard()
        }
    }

    private func retryConnection() {
        guard isRetryingConnection == false else { return }
        isRetryingConnection = true
        Task { @MainActor in
            await refresh()
            isRetryingConnection = false
        }
    }

    @ViewBuilder
    private var connectionNoticeIndicator: some View {
        if showsProgressIndicator {
            ProgressView()
                .controlSize(.small)
                .tint(ToasttyDesignTokens.amber)
        } else {
            Image(systemName: controller.freshness == .unreachable
                ? "wifi.slash"
                : "arrow.trianglehead.2.clockwise.rotate.90")
        }
    }

    private var showsProgressIndicator: Bool {
        controller.freshness == .reconnecting || controller.freshness == .connecting
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) {
                brand
                Spacer(minLength: 12)
                connection
                settingsButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    brand
                    Spacer(minLength: 12)
                    settingsButton
                }
                connection
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private var brand: some View {
        Text("TOASTTY")
            .font(.headline.monospaced())
            .fontWeight(.bold)
            .tracking(3.2)
            .foregroundStyle(ToasttyDesignTokens.primaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private var connection: some View {
        ToasttyConnectionPill(
            state: controller.connectionState,
            hostName: controller.snapshot.hostName
        )
    }

    private var settingsButton: some View {
        Button(action: onSettings) {
            Image(systemName: "gearshape")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(ToasttyDesignTokens.raisedSurface, in: Circle())
                .overlay {
                    Circle().stroke(ToasttyDesignTokens.border)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(ToasttyDesignTokens.mutedText)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("toastty-mobile-settings-button")
    }
}
