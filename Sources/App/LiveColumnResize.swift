import CoreState
import SwiftUI

enum ResizingColumn: Equatable {
    case sidebar, dock
    case rightPanel(workspaceID: UUID, tabID: UUID)

    func width(from start: CGFloat, translation: CGFloat, availableWidth: CGFloat) -> CGFloat {
        switch self {
        case .sidebar:
            WindowState.clampedSidebarWidth(start + translation)
        case .dock:
            min(max(start + translation, WindowState.minCoordinatorDockWidth),
                WindowState.maxCoordinatorDockWidth(windowWidth: availableWidth))
        case .rightPanel:
            RightAuxPanelState.clampedWidth(start - translation, for: availableWidth)
        }
    }
}

/// Transient geometry belongs to the window, not the persisted AppState.
@MainActor @Observable
final class LiveColumnResize {
    private var column: ResizingColumn?
    private var previewWidth: CGFloat?
    private var startWidth: CGFloat = 0
    private(set) var heldWorkspaceWidth: CGFloat?

    func width(for column: ResizingColumn) -> CGFloat? {
        self.column == column ? previewWidth : nil
    }

    func begin(_ column: ResizingColumn, width: CGFloat, holdingWorkspaceAt heldWidth: CGFloat? = nil) {
        self.column = column
        startWidth = width
        previewWidth = width
        heldWorkspaceWidth = heldWidth
    }

    func update(_ column: ResizingColumn, translation: CGFloat, availableWidth: CGFloat) {
        guard self.column == column else { return }
        previewWidth = column.width(from: startWidth, translation: translation, availableWidth: availableWidth)
    }

    func finish(_ column: ResizingColumn, translation: CGFloat, availableWidth: CGFloat) -> CGFloat? {
        guard self.column == column else { return nil }
        let width: CGFloat
        if case .rightPanel = column {
            // Remember the requested width, even if today's viewport can only
            // show part of it. The panel can grow into it in a wider window.
            width = RightAuxPanelState.clampedWidth(startWidth - translation)
        } else {
            width = column.width(from: startWidth, translation: translation, availableWidth: availableWidth)
        }
        cancel(column)
        return translation != 0 && width != startWidth ? width : nil
    }

    func cancel(_ column: ResizingColumn) {
        guard self.column == column else { return }
        self.column = nil
        previewWidth = nil
        heldWorkspaceWidth = nil
    }
}

struct ResizableColumnFrame: ViewModifier {
    let column: ResizingColumn
    let savedWidth: CGFloat
    let resize: LiveColumnResize

    func body(content: Content) -> some View {
        content.frame(width: resize.width(for: column) ?? savedWidth)
    }
}
