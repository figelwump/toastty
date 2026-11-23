import AppKit
import CoreState
import Foundation
import SwiftUI

/// A task's context menu items, with a divider between sections. The rows
/// that stand for a task in the sidebar and the Tasks view all show these.
struct TaskContextMenuItems: View {
    let sections: [[TaskBoardPresentation.MenuItem]]
    let run: (TaskBoardPresentation.MenuItem) -> Void

    var body: some View {
        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            if index > 0 {
                Divider()
            }
            ForEach(section, id: \.self) { item in
                Button(item.title, role: item.isDestructive ? .destructive : nil) { run(item) }
            }
        }
    }
}
