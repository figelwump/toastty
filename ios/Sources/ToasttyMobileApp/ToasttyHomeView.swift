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
            guard !conversations.isEmpty || !workspace.panels.isEmpty else { return nil }
            return MobileWorkspace(
                id: workspace.id,
                title: workspace.title,
                conversations: conversations,
                panels: workspace.panels
            )
        }
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
            LazyVStack(spacing: 10) {
                workspaceContent
            }
            // Reorders now happen only on status-bucket transitions, so
            // animating them keeps a moving card trackable instead of
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
                        ToasttySessionCard(
                            conversation: conversation,
                            freshness: controller.freshness,
                            showsWorkspace: false,
                            accessibilityIdentifier:
                                "toastty-mobile-grouped-card-\(conversation.id.uuidString)",
                            onOpen: controller.open
                        )
                    }
                } header: {
                    workspaceHeader(workspace)
                }
            }
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
        .accessibilityLabel(
            "\(workspace.title), \(sessionCountLabel(workspace.conversations.count))"
        )
        .accessibilityHint("Opens the workspace")
        .accessibilityIdentifier("toastty-mobile-workspace-\(workspace.id.uuidString)")
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

struct ToasttySessionCard: View {
    let conversation: MobileConversation
    let freshness: LiveProjectionFreshness
    let showsWorkspace: Bool
    let accessibilityIdentifier: String
    let onOpen: (MobileConversation) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button {
            onOpen(conversation)
        } label: {
            VStack(alignment: .leading, spacing: isIdle ? 6 : 8) {
                Text(conversation.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.primaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                if isIdle {
                    idleContent
                } else {
                    statusHeader
                    activityBody
                }
                metadata
            }
            .padding(.horizontal, 13)
            .padding(.vertical, isIdle ? 10 : 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .overlay {
                RoundedRectangle(
                    cornerRadius: ToasttyDesignTokens.cardCornerRadius,
                    style: .continuous
                )
                .stroke(cardBorder, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(
                cornerRadius: ToasttyDesignTokens.cardCornerRadius,
                style: .continuous
            ))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(statusPresentation.accessibilitySummary(for: conversation))
        .accessibilityHint("Opens the conversation")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var isIdle: Bool {
        conversation.state.bucket == .idle
    }

    @ViewBuilder
    private var idleContent: some View {
        if dynamicTypeSize.isAccessibilitySize {
            if let workspaceLabel { workspaceChip(workspaceLabel) }
            idleActivityText
        } else if let workspaceLabel {
            HStack(spacing: 8) {
                workspaceChip(workspaceLabel)
                Spacer(minLength: 8)
                activityDestination
            }
            idleActivityText
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                idleActivityText
                    .frame(maxWidth: .infinity, alignment: .leading)
                activityDestination
            }
        }
    }

    private var idleActivityText: some View {
        Text(conversation.lastActivity)
            .font(.subheadline)
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var statusHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                if let workspaceLabel { workspaceChip(workspaceLabel) }
                statusLabel
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let workspaceLabel {
                    workspaceChip(workspaceLabel)
                    Spacer(minLength: 8)
                    statusLabel
                        .fixedSize()
                        .layoutPriority(1)
                } else {
                    statusLabel
                    Spacer(minLength: 8)
                }
                activityDestination
            }
        }
    }

    private func workspaceChip(_ title: String) -> some View {
        Text(title)
            .font(.caption2.monospaced())
            .foregroundStyle(ToasttyDesignTokens.primaryText)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(ToasttyDesignTokens.chipSurface, in: RoundedRectangle(
                cornerRadius: ToasttyDesignTokens.chipCornerRadius,
                style: .continuous
            ))
            .overlay {
                RoundedRectangle(
                    cornerRadius: ToasttyDesignTokens.chipCornerRadius,
                    style: .continuous
                )
                .stroke(ToasttyDesignTokens.chipBorder, lineWidth: 1)
            }
    }

    private var statusLabel: some View {
        ToasttySessionStatusLabel(
            bucket: conversation.state.bucket,
            freshness: freshness
        )
    }

    private var statusPresentation: ToasttySessionStatusPresentation {
        ToasttySessionStatusPresentation(
            bucket: conversation.state.bucket,
            freshness: freshness
        )
    }

    private var activityDestination: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(ToasttyDesignTokens.mutedText)
            .accessibilityHidden(true)
    }

    private var activityBody: some View {
        Text(conversation.lastActivity)
            .font(bodyFont)
            .foregroundStyle(bodyForegroundStyle)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var bodyFont: Font {
        conversation.state.bucket == .working ? .subheadline.italic() : .subheadline
    }

    private var bodyForegroundStyle: Color {
        conversation.state.bucket == .working
            ? ToasttyDesignTokens.secondaryText
            : ToasttyDesignTokens.primaryText
    }

    private var metadata: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let label = trailingMetadataLabel
            if !label.isEmpty {
                Text(label)
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.middle)
                    .font(.caption2.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var workspaceLabel: String? {
        guard showsWorkspace else { return nil }
        let title = conversation.workspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private var trailingMetadataLabel: String {
        [
            conversation.abbreviatedCWD,
            conversation.agent.displayName,
            conversation.displayAge,
        ]
        .compactMap { value in
            guard let value, value.isEmpty == false else { return nil }
            return value
        }
        .joined(separator: " · ")
    }

    // Tint strength tracks urgency: needs-approval reads loudest, error next,
    // and ready stays calm so finished sessions don't compete for attention.
    private var cardBackground: Color {
        switch conversation.state.bucket {
        case .needsApproval:
            ToasttyDesignTokens.color(for: .needsApproval).opacity(0.16)
        case .error:
            ToasttyDesignTokens.color(for: .error).opacity(0.14)
        case .ready:
            ToasttyDesignTokens.color(for: .ready).opacity(0.07)
        case .working, .idle:
            ToasttyDesignTokens.raisedSurface
        }
    }

    private var cardBorder: Color {
        switch conversation.state.bucket {
        case .needsApproval:
            ToasttyDesignTokens.color(for: .needsApproval).opacity(0.55)
        case .error:
            ToasttyDesignTokens.color(for: .error).opacity(0.50)
        case .ready:
            ToasttyDesignTokens.color(for: .ready).opacity(0.28)
        case .working, .idle:
            ToasttyDesignTokens.border
        }
    }
}
