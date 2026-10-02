import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

struct ToasttyWorkspaceView: View {
    private static let sessionLimit = 5
    private static let panelLimit = 4

    @State private var showsAllSessions = false
    @State private var showsAllPanels = false
    let workspaceID: UUID
    let controller: HomeScreenController
    let openWorkspace: (UUID) -> Void

    @AppStorage private var storedWorkspaceSessionFilter: String
    @State private var spawnerFilter: ToasttySpawnerChip?
    @State private var infoConversation: ToasttySessionInfoSelection?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        workspaceID: UUID,
        controller: HomeScreenController,
        openWorkspace: @escaping (UUID) -> Void = { _ in },
        defaults: UserDefaults = .standard
    ) {
        self.workspaceID = workspaceID
        self.controller = controller
        self.openWorkspace = openWorkspace
        _storedWorkspaceSessionFilter = AppStorage(
            wrappedValue: ToasttyWorkspaceSessionFilter.defaultFilter.rawValue,
            ToasttyWorkspaceSessionFilter.preferenceKey,
            store: defaults
        )
    }

    var body: some View {
        Group {
            if let workspace = controller.workspace(id: workspaceID) {
                workspaceList(workspace)
            } else {
                ContentUnavailableView(
                    "Workspace no longer available",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("It was removed from Toastty on your Mac.")
                )
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .accessibilityIdentifier("toastty-mobile-workspace-removed")
            }
        }
        .background(ToasttyDesignTokens.background)
        .toasttySubspaceDoneNotice(controller)
        .sheet(item: $infoConversation) { selection in
            ToasttySessionInfoSheet(conversationID: selection.id, controller: controller)
        }
        .navigationTitle(controller.workspace(id: workspaceID)?.title ?? "Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier("toastty-mobile-workspace-detail")
        .onAppear {
            if ToasttyWorkspaceSessionFilter(rawValue: storedWorkspaceSessionFilter) == nil {
                storedWorkspaceSessionFilter =
                    ToasttyWorkspaceSessionFilter.defaultFilter.rawValue
            }
        }
    }

    private func workspaceList(_ workspace: MobileWorkspace) -> some View {
        let filteredConversations = selectedWorkspaceSessionFilter.conversations(in: workspace)
        let visibleConversations = showsAllSessions
            ? filteredConversations
            : Array(filteredConversations.prefix(Self.sessionLimit))
        let sortedPanels = ToasttyWorkspacePanels.sorted(workspace.panels)
        let visiblePanels = showsAllPanels ? sortedPanels : Array(sortedPanels.prefix(Self.panelLimit))
        let folderHints = ToasttyWorkspacePanels.folderHints(sortedPanels)
        let subspaceRows = selectedWorkspaceSessionFilter.subspaceRows(of: workspace.id, in: controller.snapshot)
        let subspaceTotal = controller.snapshot.subspaceRows(of: workspace.id).count
        let parent = controller.snapshot.parent(of: workspace.id)
        // A List rather than a ScrollView so rows have swipe actions. The
        // screen's other content rides along as rows without separators.
        // Sessions lead because they are the live work; subspaces follow
        // them as on Home, and panels, the work's output, come last.
        return List {
            Group {
                if parent != nil || !workspace.annotations.isEmpty {
                    // A subspace says where it is nested; Back returns to
                    // wherever it was opened from.
                    ToasttyWorkspaceDetailHeader(parentTitle: parent?.title, annotations: workspace.annotations)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
                sessionsHeader(shown: filteredConversations.count, total: workspace.conversations.count)
            }
            .toasttyListRow(vertical: 0)

            Group {
                if visibleConversations.isEmpty, subspaceTotal > 0 {
                    // The subspaces below are this workspace's content.
                    EmptyView()
                } else if visibleConversations.isEmpty {
                    ContentUnavailableView(
                        workspace.conversations.isEmpty
                            ? "No sessions yet"
                            : "No active sessions",
                        systemImage: "rectangle.stack",
                        description: Text(
                            workspace.conversations.isEmpty
                                ? "Open a session in Toastty on your Mac and it will appear here."
                                : "Choose All to show idle sessions in this workspace."
                        )
                    )
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("toastty-mobile-workspace-empty")
                    .toasttyListRow()
                } else {
                    ForEach(visibleConversations) { conversation in
                        let chip = ToasttySpawnerChip.chip(
                            for: conversation, in: controller.snapshot,
                            filter: selectedWorkspaceSessionFilter
                        )
                        ToasttySessionRow(
                            conversation: conversation,
                            freshness: controller.freshness,
                            accessibilityIdentifier:
                                "toastty-mobile-workspace-session-\(conversation.id.uuidString)",
                            spawnerChip: chip,
                            isSpawnerFilterActive: chip != nil
                                && spawnerFilter?.conversationID == conversation.id,
                            onSpawnerChip: { toggleSpawnerFilter($0, in: workspace) },
                            canFlag: controller.canFlagConversations,
                            onFlag: { controller.setConversationFlag(conversation.id, isFlagged: $0) },
                            onOpen: onOpen
                        )
                        .toasttyListRow()
                        .toasttySessionSwipeActions(
                            conversation, controller: controller, infoConversation: $infoConversation
                        )
                    }
                    if filteredConversations.count > Self.sessionLimit {
                        showMoreButton(
                            isExpanded: showsAllSessions,
                            hiddenCount: filteredConversations.count - Self.sessionLimit,
                            identifier: "toastty-workspace-sessions-toggle"
                        ) {
                            showsAllSessions.toggle()
                        }
                    }
                }
                if !subspaceRows.isEmpty {
                    ToasttySubspaceGroup(
                        parent: workspace,
                        rows: subspaceRows,
                        total: subspaceTotal,
                        controller: controller,
                        spawnerFilter: $spawnerFilter,
                        openWorkspace: openWorkspace
                    )
                }
            }

            if !workspace.panels.isEmpty {
                Group {
                    sectionHeader("PANELS", count: "\(sortedPanels.count)")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(sortedPanels.count) \(sortedPanels.count == 1 ? "panel" : "panels")")
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("toastty-workspace-panels-header")
                        .padding(.top, 14)
                        .toasttyListRow(vertical: 0)
                    ForEach(visiblePanels) { panel in
                        // The row draws its own chevron; a bare navigation
                        // link in a List would add a second one.
                        ToasttyWorkspacePanelRow(panel: panel, folderHint: folderHints[panel.panelID])
                            .background {
                                NavigationLink(value: ToasttyMobileRoute.panelPreview(
                                    workspaceID: workspace.id, panelID: panel.panelID
                                )) { EmptyView() }
                                .opacity(0)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("toastty-workspace-panel-\(panel.panelID.uuidString)")
                            .toasttyListRow()
                    }
                    if sortedPanels.count > Self.panelLimit {
                        showMoreButton(
                            isExpanded: showsAllPanels,
                            hiddenCount: sortedPanels.count - Self.panelLimit,
                            identifier: "toastty-workspace-panels-toggle"
                        ) {
                            showsAllPanels.toggle()
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .contentMargins(.bottom, 40, for: .scrollContent)
        // Reorders happen only on status-bucket transitions; animate so
        // the moving row stays trackable.
        .animation(
            reduceMotion ? nil : .default,
            value: visibleConversations.map(\.id) + subspaceRows.map(\.id)
        )
        .scrollIndicators(.hidden)
        .background(ToasttyDesignTokens.background)
    }

    /// Matches the subspace group's header, which sits right below it.
    private func sectionHeader(_ title: String, count: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .tracking(0.8)
            Text(count)
        }
        .font(.caption2.monospaced())
        .foregroundStyle(ToasttyDesignTokens.mutedText)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    /// The filter shares Home's setting, so choosing here changes Home too.
    private func sessionsHeader(shown: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            sectionHeader("SESSIONS", count: ToasttySubspaceGroupPresentation.countLabel(shown: shown, total: total))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    shown == total ? sessionCountLabel(total) : "\(shown) of \(sessionCountLabel(total))"
                )
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("toastty-mobile-workspace-context")
            workspaceSessionFilterMenu
        }
    }

    private var workspaceSessionFilterMenu: some View {
        Menu {
            Picker("Sessions", selection: workspaceSessionFilterSelection) {
                ForEach(ToasttyWorkspaceSessionFilter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(selectedWorkspaceSessionFilter.title)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(ToasttyDesignTokens.amberText)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 36)
            .contentShape(Rectangle())
        }
        // Keeps taps elsewhere in the header row from opening the menu.
        .buttonStyle(.borderless)
        .accessibilityLabel("Session filter")
        .accessibilityValue(selectedWorkspaceSessionFilter.title)
        .accessibilityIdentifier("toastty-mobile-workspace-detail-session-filter")
    }

    private func showMoreButton(
        isExpanded: Bool,
        hiddenCount: Int,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(isExpanded ? "Show less" : "Show \(hiddenCount) more", action: action)
            .font(.caption.weight(.medium))
            .foregroundStyle(ToasttyDesignTokens.amberText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .accessibilityIdentifier(identifier)
            .toasttyListRow(vertical: 0)
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

    /// A chip whose subspaces sit under another workspace opens that
    /// workspace, since this screen lists only its own.
    private func toggleSpawnerFilter(_ chip: ToasttySpawnerChip, in workspace: MobileWorkspace) {
        guard chip.parentWorkspaceID == workspace.id else {
            openWorkspace(chip.parentWorkspaceID)
            return
        }
        spawnerFilter = spawnerFilter?.conversationID == chip.conversationID ? nil : chip
    }

    private func onOpen(_ conversation: MobileConversation) {
        controller.open(conversation)
    }

    private func sessionCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "session" : "sessions")"
    }
}

/// One line per panel: the icon carries its kind, so the row spends its
/// width on the title. A folder hint tells same-titled panels apart.
private struct ToasttyWorkspacePanelRow: View {
    let panel: RemoteWorkspacePanel
    let folderHint: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // One timeline for the visible and spoken ages so both stay current.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let age = panel.updatedAt.map { ToasttyWorkspacePanels.age($0, now: context.date) }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: Self.symbol(for: panel.kind))
                    .font(.subheadline)
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
                    .frame(width: 20)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(panel.title)
                        .font(.subheadline)
                        .foregroundStyle(ToasttyDesignTokens.primaryText)
                    if let folderHint {
                        Text(folderHint)
                            .font(.caption)
                            .foregroundStyle(ToasttyDesignTokens.mutedText)
                            // The hint's first folder is the one that differs.
                            .truncationMode(.tail)
                            .layoutPriority(1)
                    }
                }
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                Spacer(minLength: 8)
                if let age {
                    Text(age)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(age: age))
        }
    }

    private func accessibilityLabel(age: String?) -> String {
        var parts = [panel.title]
        if let folderHint { parts.append("in \(folderHint)") }
        parts.append(Self.kindName(for: panel.kind))
        if let age {
            parts.append(age == "now" ? "updated just now" : "updated \(age) ago")
        }
        return parts.joined(separator: ", ")
    }

    private static func symbol(for kind: String) -> String {
        switch kind {
        case "scratchpad": "square.on.square"
        case "browser": "globe"
        default: "doc.text"
        }
    }

    private static func kindName(for kind: String) -> String {
        kind == "localDocument" ? "Document" : kind.capitalized
    }
}
