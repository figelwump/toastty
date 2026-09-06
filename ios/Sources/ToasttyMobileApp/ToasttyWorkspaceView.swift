import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

struct ToasttyWorkspaceView: View {
    @State private var selectedPreview: ToasttyPreviewSelection?
    @State private var selectedScratchpad: ToasttyPreviewSelection?
    let workspaceID: UUID
    let controller: HomeScreenController

    @AppStorage private var storedWorkspaceSessionFilter: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        workspaceID: UUID,
        controller: HomeScreenController,
        defaults: UserDefaults = .standard
    ) {
        self.workspaceID = workspaceID
        self.controller = controller
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
        .sheet(item: $selectedPreview) { ToasttyPreviewSheet(selection: $0) }
        .fullScreenCover(item: $selectedScratchpad) { ToasttyPreviewSheet(selection: $0) }
        .background(ToasttyDesignTokens.background)
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
        let visibleConversations = selectedWorkspaceSessionFilter.conversations(in: workspace)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !workspace.panels.isEmpty {
                    Text("Open panels").font(.headline).padding(.horizontal, 6)
                    ForEach(workspace.panels) { panel in
                        Button {
                            let selection = ToasttyPreviewSelection(
                                target: .panel(workspaceID: workspace.id, panelID: panel.panelID), title: panel.title)
                            if panel.kind == "scratchpad" { selectedScratchpad = selection }
                            else { selectedPreview = selection }
                        } label: {
                            ToasttyWorkspacePanelRow(panel: panel)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("toastty-workspace-panel-\(panel.panelID.uuidString)")
                    }
                    Text("Sessions").font(.headline).padding(.horizontal, 6).padding(.top, 14)
                }
                workspaceSessionFilterPicker

                Text(sessionCountLabel(visibleConversations.count))
                    .font(.caption2.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .padding(.horizontal, 6)
                    .accessibilityIdentifier("toastty-mobile-workspace-context")

                if visibleConversations.isEmpty {
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
                    .padding(.vertical, 24)
                    .accessibilityIdentifier("toastty-mobile-workspace-empty")
                } else {
                    ForEach(visibleConversations) { conversation in
                        ToasttySessionCard(
                            conversation: conversation,
                            freshness: controller.freshness,
                            showsWorkspace: false,
                            accessibilityIdentifier:
                                "toastty-mobile-workspace-session-\(conversation.id.uuidString)",
                            onOpen: onOpen
                        )
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 40)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            // Reorders happen only on status-bucket transitions; animate so
            // the moving card stays trackable.
            .animation(reduceMotion ? nil : .default, value: visibleConversations.map(\.id))
        }
        .scrollIndicators(.hidden)
        .background(ToasttyDesignTokens.background)
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

    private func onOpen(_ conversation: MobileConversation) {
        controller.open(conversation)
    }

    private func sessionCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "session" : "sessions")"
    }
}

private struct ToasttyWorkspacePanelRow: View {
    let panel: RemoteWorkspacePanel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: panel.kind == "scratchpad" ? "square.on.square" : panel.kind == "browser" ? "globe" : "doc.text")
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
            VStack(alignment: .leading, spacing: 4) {
                Text(panel.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(panel.kind == "localDocument" ? "Document" : panel.kind.capitalized) · \(panel.workspaceTabTitle)")
                    .font(.caption).foregroundStyle(ToasttyDesignTokens.secondaryText).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(ToasttyDesignTokens.mutedText)
        }
        .padding(14).background(ToasttyDesignTokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 12))
    }
}
