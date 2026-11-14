import AppKit
@testable import ConversationUI
import QuartzCore
import SwiftUI
@testable import ToasttyApp
import XCTest

/// Core Animation draws the working indicators, outside SwiftUI's updates.
/// These tests cover what an indicator must keep doing there: move while it
/// shows, stand still when asked, stay in step with its equals, and leave
/// clicks to the control that shows it.
@MainActor
final class ToasttyLayerAnimationViewTests: XCTestCase {
    private static let rotation = ToasttyLayerAnimationView.Animation.Property.rotation.rawValue

    func testSpinnerTurnsWhileItShowsAlsoAfterItLeavesAWindowOrIsHidden() throws {
        let (hostingView, window) = Self.host(Self.spinner(animates: true))
        defer { window.close() }
        let layerView = try Self.layerView(in: hostingView)
        XCTAssertEqual(layerView.playingAnimationKeys, [[Self.rotation]])

        window.contentView = nil
        Self.pump()
        window.contentView = hostingView
        Self.pump()
        XCTAssertEqual(layerView.playingAnimationKeys, [[Self.rotation]], "after it left the window and returned")

        hostingView.isHidden = true
        Self.pump()
        hostingView.isHidden = false
        Self.pump()
        XCTAssertEqual(layerView.playingAnimationKeys, [[Self.rotation]], "after it was hidden and shown")

        window.orderOut(nil)
        Self.pump()
        window.orderFrontRegardless()
        Self.pump()
        XCTAssertEqual(layerView.playingAnimationKeys, [[Self.rotation]], "after its window left the screen and returned")
    }

    /// With Reduce Motion an indicator shows its resting pose. The setting
    /// can change while the indicator shows.
    func testIndicatorStandsStillWhenItMustNotAnimate() throws {
        let motion = Motion()
        let (hostingView, window) = Self.host(MotionHarness(motion: motion))
        defer { window.close() }
        let layerView = try Self.layerView(in: hostingView)
        XCTAssertEqual(layerView.playingAnimationKeys, [[Self.rotation]])

        motion.animates = false
        Self.pump()
        XCTAssertEqual(layerView.playingAnimationKeys, [[]])

        motion.animates = true
        Self.pump()
        XCTAssertEqual(layerView.playingAnimationKeys, [[Self.rotation]])
    }

    /// Indicators that start at different times follow one clock: their
    /// cycles start a whole number of cycles apart.
    func testEqualAnimationsStartedAtDifferentTimesMoveInStep() {
        let layer = CALayer()
        let cases: [ToasttyLayerAnimationView.Animation] = [
            .init(property: .rotation, values: [0, 2 * .pi], duration: 0.9),
            .init(property: .opacity, values: [0.35, 0.95], duration: 1, autoreverses: true, delay: -0.7),
            .init(property: .offsetY, values: [0, -10], easing: .easeOutQuadratic, duration: 1.6, delay: 0.5),
        ]
        for animation in cases {
            let cycle = animation.cycleDuration
            let starts = [1_000.25, 1_000.6, 1_007.93].map { now -> CFTimeInterval in
                let begin = animation.coreAnimation(now: now, on: layer).beginTime
                XCTAssertLessThanOrEqual(begin, now)
                XCTAssertLessThan(now - begin, cycle + 1e-9, "The cycle that plays now started less than one cycle ago")
                return begin
            }
            for start in starts.dropFirst() {
                let cyclesApart = (start - starts[0]) / cycle
                XCTAssertEqual(cyclesApart, cyclesApart.rounded(), accuracy: 1e-6, "\(animation.property)")
            }
            // A delay moves the cycle against the shared clock by that time.
            let position = animation.cyclePosition(now: 1_000.25)
            let expected = (1_000.25 - animation.delay).truncatingRemainder(dividingBy: cycle)
            XCTAssertEqual(position, expected, accuracy: 1e-9)
        }
    }

    /// A button or a row shows an indicator inside its label. A click on the
    /// indicator must reach that control, and the indicator's own view must
    /// not take the pointer. The first button's label is plain SwiftUI: it
    /// shows that the test's clicks arrive at all.
    func testAClickOnAnIndicatorReachesTheButtonThatShowsIt() throws {
        let clicks = Clicks()
        let size = CGSize(width: 200, height: 80)
        let (hostingView, window) = Self.host(
            HStack(spacing: 40) {
                Button { clicks.plain += 1 } label: {
                    Circle().fill(.orange).frame(width: 40, height: 40)
                }
                Button { clicks.indicator += 1 } label: { Self.spinner(animates: true) }
            }
            .buttonStyle(.plain),
            size: size
        )
        defer { window.close() }
        let layerView = try Self.layerView(in: hostingView)
        let indicatorCenter = layerView.convert(
            CGPoint(x: layerView.bounds.midX, y: layerView.bounds.midY),
            to: hostingView
        )
        // The plain button is one label and one gap to the left.
        let plainCenter = CGPoint(x: indicatorCenter.x - 80, y: indicatorCenter.y)

        let hit = hostingView.hitTest(hostingView.convert(indicatorCenter, to: hostingView.superview))
        XCTAssertFalse(hit is ToasttyLayerAnimationNSView, "The indicator's view took the pointer")

        try Self.click(at: plainCenter, in: hostingView)
        try XCTSkipIf(clicks.plain == 0, "This test host does not deliver clicks to SwiftUI buttons")
        try Self.click(at: indicatorCenter, in: hostingView)
        XCTAssertEqual(clicks.indicator, 1)
        XCTAssertEqual(clicks.plain, 1)
    }

    /// A workspace tab sits in the window's hidden titlebar and shows a
    /// spinner while its session works. A press on the spinner must stay
    /// with the tab's own region, which never moves the window.
    func testAPressOnATabsSpinnerStaysInTheTabsRegion() throws {
        let size = CGSize(width: 160, height: 40)
        let (hostingView, window) = Self.host(
            NonWindowDraggableRegion {
                HStack(spacing: 5) {
                    SessionStatusIndicator(state: .spinner, size: 8, lineWidth: 1.4)
                    Text("Terminal 1")
                }
                .frame(width: 120, height: 28)
                .contentShape(Rectangle())
            },
            size: size
        )
        defer { window.close() }
        let region = try XCTUnwrap(Self.find(NonWindowDraggableContainerView.self, in: hostingView))
        let layerView = try Self.layerView(in: region)
        let spinnerCenter = layerView.convert(
            CGPoint(x: layerView.bounds.midX, y: layerView.bounds.midY),
            to: region.superview
        )

        let hit = try XCTUnwrap(region.hitTest(spinnerCenter), "The tab's region did not take a press on its spinner")
        XCTAssertFalse(hit is ToasttyLayerAnimationNSView, "The indicator's view took the pointer")
        XCTAssertFalse(hit.mouseDownCanMoveWindow, "A press on a tab's spinner would move the window")
    }

    // MARK: - Support

    @MainActor
    private final class Motion: ObservableObject {
        @Published var animates = true
    }

    @MainActor
    private final class Clicks {
        var plain = 0
        var indicator = 0
    }

    private struct MotionHarness: View {
        @ObservedObject var motion: Motion

        var body: some View {
            ToasttyLayerAnimationViewTests.spinner(animates: motion.animates)
        }
    }

    private static func spinner(animates: Bool) -> some View {
        ToasttyLayerAnimationView(
            shapes: [.spinnerArc(size: 40, lineWidth: 4, color: .orange)],
            animates: animates
        )
        .frame(width: 40, height: 40)
    }

    private static func host<Content: View>(
        _ content: Content,
        size: CGSize = CGSize(width: 80, height: 80)
    ) -> (NSHostingView<some View>, NSWindow) {
        let hostingView = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        // Far outside every screen, so the window never shows.
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        pump(0.5)
        hostingView.layoutSubtreeIfNeeded()
        return (hostingView, window)
    }

    private static func layerView(in view: NSView) throws -> ToasttyLayerAnimationNSView {
        try XCTUnwrap(find(ToasttyLayerAnimationNSView.self, in: view), "The indicator has no layer view")
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    private static func pump(_ seconds: TimeInterval = 0.15) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func click(at point: CGPoint, in view: NSView) throws {
        try send(.leftMouseDown, at: point, in: view)
        pump(0.05)
        try send(.leftMouseUp, at: point, in: view)
        pump(0.4)
    }

    private static func send(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) throws {
        let window = try XCTUnwrap(view.window)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        ))
        window.sendEvent(event)
    }
}
