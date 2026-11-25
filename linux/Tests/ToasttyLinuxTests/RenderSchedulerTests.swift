import CGtk
import Testing
@testable import ToasttyLinuxUI

/// `RenderScheduler` keeps a render that triggers itself from starving GTK's
/// layout and paint, which run at `GDK_PRIORITY_REDRAW`.
@Suite("Render scheduling")
@MainActor
struct RenderSchedulerTests {
    /// GDK_PRIORITY_REDRAW (a macro Swift does not import).
    static let redrawPriority = Int32(G_PRIORITY_HIGH_IDLE) + 20

    @Test func renderThatSchedulesItselfLetsThePaintRun() {
        var runs = 0
        var runsBeforePaint: Int?
        var scheduler: RenderScheduler?
        scheduler = RenderScheduler("test-loop") {
            runs += 1
            // A render that changes state its own view observes.
            if runs < 500 { scheduler?.schedule() }
        }
        scheduler?.schedule()
        MainLoop.idle(priority: Self.redrawPriority) { runsBeforePaint = runs }
        MainLoop.spin(untilMilliseconds: 2000) { runsBeforePaint != nil }
        // The first run is ahead of the paint; the re-render it asked for
        // waits for it.
        #expect(runsBeforePaint == 1)
        withExtendedLifetime(scheduler) {}
    }

    @Test func requestFromOutsideARenderRunsBeforeThePaint() {
        var order: [String] = []
        let scheduler = RenderScheduler("test-outside") { order.append("render") }
        scheduler.schedule()
        MainLoop.idle(priority: Self.redrawPriority) { order.append("paint") }
        MainLoop.spin(untilMilliseconds: 2000) { order.count == 2 }
        #expect(order == ["render", "paint"])
    }

    @Test func outsideRequestPromotesADeferredRender() {
        var order: [String] = []
        var otherRan = false
        var target: RenderScheduler?
        target = RenderScheduler("test-target") { order.append("target") }
        // A render of another view asks `target` to render: deferred.
        let other = RenderScheduler("test-other") {
            target?.schedule()
            otherRan = true
        }
        other.schedule()
        MainLoop.spin(untilMilliseconds: 2000) { otherRan }
        #expect(target?.isScheduled == true)
        // Then an outside change asks again: it runs ahead of the paint.
        target?.schedule()
        MainLoop.idle(priority: Self.redrawPriority) { order.append("paint") }
        MainLoop.spin(untilMilliseconds: 2000) { order.count == 2 }
        #expect(order == ["target", "paint"])
    }

    @Test func pendingRenderIsCoalesced() {
        var runs = 0
        let scheduler = RenderScheduler("test-coalesce") { runs += 1 }
        scheduler.schedule()
        scheduler.schedule()
        scheduler.schedule()
        MainLoop.spin(untilMilliseconds: 200)
        #expect(runs == 1)
        #expect(scheduler.isScheduled == false)
    }
}
