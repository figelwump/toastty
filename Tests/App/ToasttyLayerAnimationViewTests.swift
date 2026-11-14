import AppKit
@testable import ConversationUI
import QuartzCore
import SwiftUI
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
    /// not take the pointer.
    func testAClickOnAnIndicatorReachesTheButtonThatShowsIt() throws {
        let clicks = Clicks()
        let size = CGSize(width: 120, height: 80)
        let (hostingView, window) = Self.host(
            Button { clicks.count += 1 } label: { Self.spinner(animates: true) }
                .buttonStyle(.plain)
                .frame(width: size.width, height: size.height),
            size: size
        )
        defer { window.close() }
        let layerView = try Self.layerView(in: hostingView)
        let center = layerView.convert(CGPoint(x: layerView.bounds.midX, y: layerView.bounds.midY), to: hostingView)

        let hit = hostingView.hitTest(hostingView.convert(center, to: hostingView.superview))
        XCTAssertFalse(hit is ToasttyLayerAnimationNSView, "The indicator's view took the pointer")

        try Self.send(.leftMouseDown, at: center, in: hostingView)
        Self.pump(0.05)
        try Self.send(.leftMouseUp, at: center, in: hostingView)
        Self.pump(0.3)
        XCTAssertEqual(clicks.count, 1)
    }

    // MARK: - Support

    @MainActor
    private final class Motion: ObservableObject {
        @Published var animates = true
    }

    @MainActor
    private final class Clicks {
        var count = 0
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
        window.contentView = hostingView
        pump(0.3)
        hostingView.layoutSubtreeIfNeeded()
        return (hostingView, window)
    }

    private static func layerView(in view: NSView) throws -> ToasttyLayerAnimationNSView {
        func find(_ view: NSView) -> ToasttyLayerAnimationNSView? {
            if let match = view as? ToasttyLayerAnimationNSView { return match }
            for subview in view.subviews {
                if let match = find(subview) { return match }
            }
            return nil
        }
        return try XCTUnwrap(find(view), "The indicator has no layer view")
    }

    private static func pump(_ seconds: TimeInterval = 0.15) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
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
