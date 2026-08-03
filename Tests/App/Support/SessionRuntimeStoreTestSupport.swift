import Combine
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
func makeTwoPanelAppState() -> AppState {
    let leftPanelID = UUID()
    let rightPanelID = UUID()
    let leftSlotID = UUID()
    let rightSlotID = UUID()
    let workspaceID = UUID()
    let windowID = UUID()
    let workspace = WorkspaceState(
        id: workspaceID,
        title: "Workspace 1",
        layoutTree: .split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: .slot(slotID: leftSlotID, panelID: leftPanelID),
            second: .slot(slotID: rightSlotID, panelID: rightPanelID)
        ),
        panels: [
            leftPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/repo")),
            rightPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/repo")),
        ],
        focusedPanelID: leftPanelID
    )
    let window = WindowState(
        id: windowID,
        frame: CGRectCodable(x: 120, y: 120, width: 1280, height: 760),
        workspaceIDs: [workspaceID],
        selectedWorkspaceID: workspaceID
    )

    return AppState(
        windows: [window],
        workspacesByID: [workspaceID: workspace],
        selectedWindowID: windowID,
        configuredTerminalFontPoints: nil
    )
}

func persistedResumeRecord(panelID: UUID, in state: AppState) -> ManagedAgentResumeRecord? {
    guard let selection = state.workspaceSelection(containingPanelID: panelID),
          case .terminal(let terminalState)? = selection.workspace.panelState(for: panelID) else {
        return nil
    }

    return terminalState.resumeRecord
}

struct RecordedSessionNotification: Equatable {
    let title: String
    let body: String
    let workspaceID: UUID
    let panelID: UUID
    let context: DesktopNotificationContext
}

actor SessionNotificationRecorder {
    private var recorded: [RecordedSessionNotification] = []

    func record(
        title: String,
        body: String,
        workspaceID: UUID,
        panelID: UUID,
        context: DesktopNotificationContext
    ) {
        recorded.append(
            RecordedSessionNotification(
                title: title,
                body: body,
                workspaceID: workspaceID,
                panelID: panelID,
                context: context
            )
        )
    }

    func notifications() -> [RecordedSessionNotification] {
        recorded
    }

    func count() -> Int {
        recorded.count
    }
}

func settleNotificationTasks(iterations: Int = 12) async {
    for _ in 0..<iterations {
        await Task.yield()
    }
}

func waitUntilNotificationCount(
    _ recorder: SessionNotificationRecorder,
    expectedCount: Int,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async {
    let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
    while await recorder.count() != expectedCount && Date() < deadline {
        await Task.yield()
    }
}

enum SessionRuntimeStoreTestSupport {
    @MainActor
    static func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
        while condition() == false && Date() < deadline {
            await Task.yield()
        }
    }
}
