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
            return workspace.withConversations(conversations)
        }
    }

    func subspaceRows(of parentID: UUID, in snapshot: MobileHomeSnapshot) -> [MobileSubspaceRow] {
        snapshot.subspaceRows(of: parentID).filter { self == .all || $0.status.isActive }
    }

    /// Home's sections: each top-level workspace with the sessions and
    /// subspaces this filter lists. A workspace whose only activity is in a
    /// subspace still appears, showing that subspace.
    func sections(in snapshot: MobileHomeSnapshot) -> [ToasttyHomeSection] {
        snapshot.topLevelWorkspaces.compactMap { workspace in
            let conversations = conversations(in: workspace)
            let rows = subspaceRows(of: workspace.id, in: snapshot)
            let keepsPanelOnlyWorkspace = self == .all && !workspace.panels.isEmpty
            guard !conversations.isEmpty || !rows.isEmpty || keepsPanelOnlyWorkspace else {
                return nil
            }
            return ToasttyHomeSection(
                workspace: workspace.withConversations(conversations),
                subspaceRows: rows,
                subspaceTotal: snapshot.subspaceRows(of: workspace.id).count
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

    /// What Home leaves out under this filter. Sessions inside a subspace
    /// are listed on the subspace's own screen, so only the row counts here.
    func hiddenCounts(in snapshot: MobileHomeSnapshot) -> ToasttyHiddenCounts {
        guard self == .active else { return ToasttyHiddenCounts() }
        var counts = ToasttyHiddenCounts(
            idleSessions: hiddenSessionCount(in: snapshot.topLevelWorkspaces)
        )
        for workspace in snapshot.topLevelWorkspaces {
            for row in snapshot.subspaceRows(of: workspace.id) where !row.status.isActive {
                if row.status == .done {
                    counts.doneSubspaces += 1
                } else {
                    counts.idleSubspaces += 1
                }
            }
        }
        return counts
    }

    static func hiddenSessionsLabel(count: Int) -> String {
        "\(count) idle \(count == 1 ? "session" : "sessions") hidden"
    }
}

struct ToasttyHomeSection: Identifiable, Equatable {
    let workspace: MobileWorkspace
    let subspaceRows: [MobileSubspaceRow]
    /// Before filtering, for the group's "shown/total" count.
    let subspaceTotal: Int

    var id: UUID { workspace.id }
}

struct ToasttyHiddenCounts: Equatable {
    var idleSessions = 0
    var idleSubspaces = 0
    var doneSubspaces = 0

    /// For example "3 idle sessions and 1 done subspace hidden"; `nil` when
    /// nothing is hidden.
    var label: String? {
        let parts = [
            Self.part(idleSessions, "idle session"),
            Self.part(idleSubspaces, "idle subspace"),
            Self.part(doneSubspaces, "done subspace"),
        ].compactMap { $0 }
        guard let last = parts.last else { return nil }
        let list = parts.count == 1
            ? last
            : parts.dropLast().joined(separator: ", ") + " and " + last
        return "\(list) hidden"
    }

    private static func part(_ count: Int, _ noun: String) -> String? {
        count == 0 ? nil : "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

/// The ⑂ chip on a session that spawned subspaces.
struct ToasttySpawnerChip: Equatable {
    enum Tone: Equatable {
        case neutral
        case needsApproval
        case error
    }

    let conversationID: UUID
    let count: Int
    let tone: Tone
    /// The workspace whose Subspaces group holds the spawned subspaces.
    let parentWorkspaceID: UUID
    /// Set when that workspace is not the session's own, since a session can
    /// nest a subspace under another workspace.
    let otherWorkspaceTitle: String?

    var accessibilityLabel: String {
        let noun = count == 1 ? "subspace" : "subspaces"
        return otherWorkspaceTitle.map { "\(count) \(noun) in \($0)" } ?? "\(count) \(noun)"
    }

    /// Subspaces in the session's own workspace come first, as on the
    /// desktop. Otherwise the chip points at the first workspace, in Home's
    /// order, that holds one. Only subspaces the filter lists count, so the
    /// chip never leads to a group that is not shown.
    static func chip(
        for conversation: MobileConversation,
        in snapshot: MobileHomeSnapshot,
        filter: ToasttyWorkspaceSessionFilter
    ) -> ToasttySpawnerChip? {
        let parentIDs = [conversation.workspaceID]
            + snapshot.topLevelWorkspaces.map(\.id).filter { $0 != conversation.workspaceID }
        for parentID in parentIDs {
            let spawned = filter.subspaceRows(of: parentID, in: snapshot).filter {
                $0.workspace.spawningConversationID == conversation.id
            }
            guard spawned.isEmpty == false else { continue }
            let tone: Tone = if spawned.contains(where: { $0.status == .error }) {
                .error
            } else if spawned.contains(where: { $0.status == .needsApproval }) {
                .needsApproval
            } else {
                .neutral
            }
            return ToasttySpawnerChip(
                conversationID: conversation.id,
                count: spawned.count,
                tone: tone,
                parentWorkspaceID: parentID,
                otherWorkspaceTitle: parentID == conversation.workspaceID
                    ? nil
                    : snapshot.workspaces.first { $0.id == parentID }?.title
            )
        }
        return nil
    }
}

struct ToasttyHomeView: View {
    let controller: HomeScreenController
    let refresh: () async -> Void
    let onSettings: () -> Void
    let openWorkspace: (UUID) -> Void
    let notificationError: String?
    let retryNotifications: () -> Void

    @AppStorage private var storedWorkspaceSessionFilter: String
    @AppStorage(ToasttyCollapsedSubspaceGroups.preferenceKey) private var storedCollapsedGroups = ""
    @State private var isRetryingConnection = false
    /// The ⑂ chip whose subspaces its group is limited to.
    @State private var spawnerFilter: ToasttySpawnerChip?
    /// The session whose detail card the Info swipe opened.
    @State private var infoConversation: ToasttySessionInfoSelection?
    @State private var newSession: ToasttyNewSessionModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let defaults: UserDefaults

    init(
        controller: HomeScreenController,
        refresh: @escaping () async -> Void = {},
        onSettings: @escaping () -> Void = {},
        openWorkspace: @escaping (UUID) -> Void = { _ in },
        notificationError: String? = nil,
        retryNotifications: @escaping () -> Void = {},
        defaults: UserDefaults = .standard
    ) {
        self.controller = controller
        self.refresh = refresh
        self.onSettings = onSettings
        self.openWorkspace = openWorkspace
        self.notificationError = notificationError
        self.retryNotifications = retryNotifications
        self.defaults = defaults
        _storedWorkspaceSessionFilter = AppStorage(
            wrappedValue: ToasttyWorkspaceSessionFilter.defaultFilter.rawValue,
            ToasttyWorkspaceSessionFilter.preferenceKey,
            store: defaults
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            // A List rather than a ScrollView so rows have swipe actions.
            List {
                workspaceContent(proxy)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
            .contentMargins(.bottom, 40, for: .scrollContent)
            // Reorders now happen only on status-bucket transitions, so
            // animating them keeps a moving row trackable instead of
            // teleporting.
            .animation(reduceMotion ? nil : .default, value: orderedRowIDs)
        }
        .refreshable {
            await refresh()
        }
        .scrollIndicators(.hidden)
        .sheet(item: $infoConversation) { selection in
            ToasttySessionInfoSheet(conversationID: selection.id, controller: controller)
        }
        .toasttyNewSessionSheet($newSession, controller: controller)
        // The identifier must precede safeAreaInset: applied after it, it
        // stamps both the scroll view and the inset header, breaking UI-test
        // queries with ambiguous matches.
        .accessibilityIdentifier("toastty-mobile-home")
        .safeAreaInset(edge: .top, spacing: 0) {
            // Connection state and the workspace filter stay visible while
            // sessions scroll underneath them.
            VStack(spacing: 10) {
                header
                if let notificationError {
                    ToasttyNotificationErrorBanner(message: notificationError, retry: retryNotifications)
                }
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
        .toasttySubspaceDoneNotice(controller)
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
        sections.flatMap { section in
            [section.id] + section.workspace.conversations.map(\.id) + section.subspaceRows.map(\.id)
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
    private func workspaceContent(_ proxy: ScrollViewProxy) -> some View {
        if sections.isEmpty {
            workspaceEmptyState
                .toasttyListRow()
        } else {
            // Plain rows rather than sections: a section header in a plain
            // List pins to the top and lets rows scroll under it.
            ForEach(sections) { section in
                Group {
                    workspaceHeader(section.workspace)
                        .padding(.top, 12)
                        .toasttyListRow(vertical: 0)
                    ForEach(section.workspace.conversations) { conversation in
                        let chip = ToasttySpawnerChip.chip(
                            for: conversation, in: controller.snapshot, filter: selectedWorkspaceSessionFilter
                        )
                        ToasttySessionRow(
                            conversation: conversation,
                            freshness: controller.freshness,
                            accessibilityIdentifier:
                                "toastty-mobile-grouped-card-\(conversation.id.uuidString)",
                            spawnerChip: chip,
                            isSpawnerFilterActive: chip != nil
                                && spawnerFilter?.conversationID == conversation.id,
                            onSpawnerChip: { toggleSpawnerFilter($0, proxy: proxy) },
                            canFlag: controller.canFlagConversations,
                            onFlag: { controller.setConversationFlag(conversation.id, isFlagged: $0) },
                            onOpen: controller.open
                        )
                        .toasttyListRow()
                        .toasttySessionSwipeActions(
                            conversation, controller: controller, infoConversation: $infoConversation
                        )
                    }
                    if section.subspaceTotal > 0, !section.subspaceRows.isEmpty {
                        ToasttySubspaceGroup(
                            parent: section.workspace,
                            rows: section.subspaceRows,
                            total: section.subspaceTotal,
                            controller: controller,
                            spawnerFilter: $spawnerFilter,
                            openWorkspace: openWorkspace
                        )
                        .id(Self.subspaceGroupID(section.id))
                    }
                }
            }
        }
        // Shown under the empty state too, so an all-idle Mac still says how
        // much Active is hiding.
        hiddenSessionsFooter
            .toasttyListRow()
    }

    private static func subspaceGroupID(_ parentID: UUID) -> String {
        "subspaces-\(parentID.uuidString)"
    }

    /// The chip limits its group to the session's subspaces; tapping it
    /// again shows them all. The group may sit under another workspace, so
    /// it is opened and scrolled into view.
    private func toggleSpawnerFilter(_ chip: ToasttySpawnerChip, proxy: ScrollViewProxy) {
        guard spawnerFilter?.conversationID != chip.conversationID else {
            spawnerFilter = nil
            return
        }
        spawnerFilter = chip
        var groups = ToasttyCollapsedSubspaceGroups(storedValue: storedCollapsedGroups)
        groups.set(chip.parentWorkspaceID, collapsed: false)
        storedCollapsedGroups = groups.storedValue
        withAnimation(reduceMotion ? nil : .default) {
            proxy.scrollTo(Self.subspaceGroupID(chip.parentWorkspaceID), anchor: .center)
        }
    }

    @ViewBuilder
    private var hiddenSessionsFooter: some View {
        if let label = selectedWorkspaceSessionFilter.hiddenCounts(in: controller.snapshot).label {
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(ToasttyDesignTokens.mutedText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
                .accessibilityIdentifier("toastty-mobile-hidden-sessions")
        }
    }

    private var sections: [ToasttyHomeSection] {
        selectedWorkspaceSessionFilter.sections(in: controller.snapshot)
    }

    /// A button rather than a navigation link, which a List would dress as a
    /// cell with its own disclosure chevron.
    private func workspaceHeader(_ workspace: MobileWorkspace) -> some View {
        Button {
            openWorkspace(workspace.id)
        } label: {
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
                newSessionButton
                settingsButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    brand
                    Spacer(minLength: 12)
                    newSessionButton
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

    /// Starts a session in the workspace of the last one started from this
    /// phone, which the sheet lets the person change.
    @ViewBuilder
    private var newSessionButton: some View {
        if controller.canStartSessions,
           let workspace = controller.defaultSessionStartWorkspace(
               lastUsed: ToasttyNewSessionPreferences(defaults: defaults).lastWorkspaceID
           ) {
            Button {
                newSession = ToasttyNewSessionModel(
                    workspaceID: workspace.id,
                    workspaceTitle: workspace.title,
                    host: controller,
                    preferences: ToasttyNewSessionPreferences(defaults: defaults)
                )
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(ToasttyDesignTokens.amber, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(ToasttyDesignTokens.inkOnAmber)
            .accessibilityLabel("New session")
            .accessibilityIdentifier("toastty-mobile-home-new-session")
        }
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
