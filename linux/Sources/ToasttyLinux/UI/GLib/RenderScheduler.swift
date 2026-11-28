import CGtk
import CoreState
import Foundation

/// Coalesces a view's redraw requests into one GLib idle callback.
///
/// A request from outside any render (a store action, a socket command, a
/// timer, a publisher) runs at `G_PRIORITY_HIGH_IDLE`, ahead of GTK's
/// layout and paint (`GDK_PRIORITY_REDRAW`), so the next frame shows it.
///
/// A request made while a scheduled render runs, which happens when a render
/// changes published state that some view observes, waits at
/// `G_PRIORITY_DEFAULT_IDLE` instead: after GTK has painted. Otherwise a
/// render that keeps triggering itself, directly or through another view,
/// re-queues ahead of the paint forever and the window stops repainting
/// until an input event forces a frame (the Tasks list updated only while
/// the pointer moved). Such a loop still costs CPU, so it is logged once.
@MainActor
final class RenderScheduler {
    /// Scheduled renders running now (they can nest: a window's render
    /// renders its features).
    private static var depth = 0
    /// Deferred runs in the current one-second window, to report loops.
    private static var deferredRunCount = 0
    private static var deferredWindowStart = Date.distantPast
    private static var lastLoopReport = Date.distantPast
    nonisolated static let loopThresholdPerSecond = 30

    let name: String
    private let action: @MainActor () -> Void
    private var sourceID: guint = 0
    private var isDeferred = false

    /// `render` must not retain the scheduler's owner strongly; capture it
    /// weakly.
    init(_ name: String, render: @escaping @MainActor () -> Void) {
        self.name = name
        action = render
    }

    isolated deinit {
        MainLoop.cancel(sourceID)
    }

    /// Whether a render is waiting to run.
    var isScheduled: Bool { sourceID != 0 }

    func schedule() {
        let deferred = Self.depth > 0
        if sourceID != 0 {
            // A deferred run is promoted when an outside change arrives;
            // anything else is already covered.
            guard isDeferred, deferred == false else { return }
            MainLoop.cancel(sourceID)
        }
        isDeferred = deferred
        let priority = deferred ? G_PRIORITY_DEFAULT_IDLE : G_PRIORITY_HIGH_IDLE
        sourceID = MainLoop.idle(priority: Int32(priority)) { [weak self] in
            self?.run()
        }
    }

    private func run() {
        sourceID = 0
        if isDeferred {
            isDeferred = false
            Self.noteDeferredRun(name)
        }
        Self.depth += 1
        defer { Self.depth -= 1 }
        action()
    }

    private static func noteDeferredRun(_ name: String) {
        let now = Date()
        if now.timeIntervalSince(deferredWindowStart) >= 1 {
            deferredWindowStart = now
            deferredRunCount = 0
        }
        deferredRunCount += 1
        guard deferredRunCount == loopThresholdPerSecond,
              now.timeIntervalSince(lastLoopReport) >= 60 else { return }
        lastLoopReport = now
        ToasttyLog.warning("A view keeps re-rendering itself", category: .app, metadata: [
            "view": name,
            "deferred_renders_per_second": "\(loopThresholdPerSecond)+",
        ])
    }
}
