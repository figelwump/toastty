import SwiftUI

/// Observes attention across all screens without adding notification state to
/// the session model. The root owns the writer so a screen change cannot
/// replace it while a permission request or system write is in flight.
struct AppIconBadgeSync: View {
    @Environment(\.scenePhase) private var scenePhase
    let sessionController: AppSessionController
    let controller: AppIconBadgeController?

    var body: some View {
        Color.clear
            .onChange(of: update, initial: true) { _, update in
                controller?.update(count: update.count, isActive: update.isActive)
            }
    }

    // One observed value makes the initial count and scene phase atomic.
    private var update: Update {
        Update(count: sessionController.appIconBadgeCount, isActive: scenePhase == .active,
               permission: sessionController.pushController?.permission)
    }

    private struct Update: Equatable {
        let count: Int?
        let isActive: Bool
        // Continue can grant permission without changing the count or scene.
        let permission: ToasttyNotificationPermission?
    }
}
