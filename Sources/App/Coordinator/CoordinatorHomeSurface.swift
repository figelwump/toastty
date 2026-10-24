import CoreState
import SwiftUI

/// Window presentation observes app-owned Peek state; the Coordinator chat is
/// never removed when the right-hand inspection changes.
struct CoordinatorHomeSurface: View {
    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var board: TaskBoardStore
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let controller: CoordinatorHomeController
    @ObservedObject var peeks: CoordinatorPeekStore
    @FocusState private var focusedComposer: CoordinatorComposer?

    var body: some View {
        CoordinatorHomeView(windowID: windowID, store: store, board: board,
            sessionRuntimeStore: sessionRuntimeStore, reviews: controller.reviews, actions: controller.actions,
            peekTask: { peeks.openTask($0, in: windowID) }, peekContent: peekContent) {
            CoordinatorChatView(session: controller.session, conversation: controller.conversation,
                openTerminal: {
                    guard let identity = controller.session.identity else { return }
                    openTerminal(workspaceID: identity.workspaceID, panelID: identity.panelID)
                }, focusedComposer: $focusedComposer)
        }
        .onAppear { focusedComposer = peeks.inspections[windowID]?.panelID == nil ? .coordinator : .peek }
        .onChange(of: peeks.inspections[windowID]?.panelID) { _, panelID in
            focusedComposer = panelID == nil ? .coordinator : .peek
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "toastty" else { return .systemAction }
            let value = url.pathComponents.dropFirst().first ?? ""
            if url.host == "task", let id = UUID(uuidString: value) {
                peeks.openTask(id, in: windowID)
                return .handled
            }
            if url.host == "session", !value.isEmpty {
                peeks.openSession(value, in: windowID)
                return .handled
            }
            return .discarded
        })
    }

    private var peekContent: AnyView? {
        guard let inspection = peeks.inspections[windowID] else { return nil }
        return AnyView(CoordinatorPeekView(inspection: inspection, close: { peeks.close(in: windowID) },
            openTerminal: {
                guard let workspaceID = inspection.workspaceID else { return }
                openTerminal(workspaceID: workspaceID, panelID: inspection.panelID)
            }, focusedComposer: $focusedComposer).id(inspection.panelID))
    }

    private func openTerminal(workspaceID: UUID, panelID: UUID?) {
        guard let destination = store.state.workspaceSelection(containingWorkspaceID: workspaceID) else { return }
        _ = store.send(.setTasksViewShown(windowID: destination.windowID, shown: false))
        if let target = panelID ?? destination.workspace.focusedPanelID {
            _ = store.focusExplicitlyNavigatedPanel(windowID: destination.windowID,
                workspaceID: workspaceID, panelID: target)
        } else {
            _ = store.selectWorkspace(windowID: destination.windowID, workspaceID: workspaceID,
                preferringUnreadSessionPanelIn: sessionRuntimeStore)
        }
    }
}

private struct CoordinatorPeekView: View {
    let inspection: CoordinatorPeekStore.Inspection
    let close: () -> Void
    let openTerminal: () -> Void
    var focusedComposer: FocusState<CoordinatorComposer?>.Binding

    var body: some View {
        Group {
            if let conversation = inspection.conversation, inspection.unavailableReason == nil {
                NativeConversationView(conversation: conversation, openTerminal: openTerminal,
                    focusedComposer: focusedComposer, pane: .peek,
                    composerLabel: "Message task agent") {
                    header
                } empty: {
                    Text("Waiting for the task conversation. Use Open task space to inspect its terminal.")
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Text(inspection.unavailableReason ?? "The task conversation is unavailable.")
                        .foregroundStyle(.secondary).padding(.horizontal, 16)
                    if let draft = inspection.conversation?.draft, !draft.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Unsent draft").font(.caption).foregroundStyle(.secondary)
                            Text(draft).textSelection(.enabled)
                        }.padding(.horizontal, 16)
                    }
                    Spacer()
                }
            }
        }
        .background(ToastyTheme.surfaceBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coordinator.peek")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: close) { Label("Back to review", systemImage: "chevron.left") }
                    .accessibilityIdentifier("coordinator.peek.close")
                Spacer()
                Button("Open task space", action: openTerminal).disabled(inspection.workspaceID == nil)
                    .accessibilityIdentifier("coordinator.peek.openTask")
            }
            Text(inspection.title).font(.headline).lineLimit(2)
        }.padding(16)
    }
}
