import Combine
import SwiftUI

/// Share pointer ownership without publishing hover changes to the sidebar.
/// A new owner also clears the old row if AppKit misses its exit event.
@MainActor
final class SidebarHoverState {
    let panel = CurrentValueSubject<UUID?, Never>(nil)
    let workspace = CurrentValueSubject<UUID?, Never>(nil)
    let subspace = CurrentValueSubject<UUID?, Never>(nil)
    let doneToggle = CurrentValueSubject<UUID?, Never>(nil)
    let toShipTask = CurrentValueSubject<UUID?, Never>(nil)
}

struct SidebarHoverRegion<Content: View>: View {
    let id: UUID
    let selection: CurrentValueSubject<UUID?, Never>
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovered = false

    init(
        id: UUID,
        selection: CurrentValueSubject<UUID?, Never>,
        @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.id = id
        self.selection = selection
        self.content = content
        _isHovered = State(initialValue: selection.value == id)
    }

    var body: some View {
        content(isHovered)
            .onReceive(selection) { ownerID in
                let value = ownerID == id
                // Only the previous and current owners need a view update.
                if isHovered != value { isHovered = value }
            }
            .onChange(of: id) { _, id in
                isHovered = selection.value == id
            }
    }
}
