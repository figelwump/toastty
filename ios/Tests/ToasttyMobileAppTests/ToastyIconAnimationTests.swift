@testable import ConversationUI
import SwiftUI
import UIKit
import XCTest
@testable import ToasttyMobileApp

/// Toasty's steam and the activity spinner on the iPhone, which Core
/// Animation moves outside SwiftUI's updates: they move while shown, move
/// again after their view leaves the window and returns, as it does when a
/// tab hides and shows, and stand still when asked.
@MainActor
final class ToastyIconAnimationTests: XCTestCase {
    private static let wispAnimations = [
        [ToasttyLayerAnimationView.Animation.Property.opacity.rawValue,
         ToasttyLayerAnimationView.Animation.Property.offsetY.rawValue].sorted(),
    ]

    func testSteamMovesWhileWorkingAndStandsStillWhenItMustNot() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil }

        let working = UIHostingController(rootView: Self.icon(.working))
        window.rootViewController = working
        window.makeKeyAndVisible()
        let steam = try layerView(in: working.view)
        XCTAssertEqual(steam.playingAnimationKeys, Array(repeating: Self.wispAnimations[0], count: 3))

        // Out of the window and back, as on a tab switch.
        window.rootViewController = UIViewController()
        pump()
        window.rootViewController = working
        pump()
        XCTAssertEqual(steam.playingAnimationKeys, Array(repeating: Self.wispAnimations[0], count: 3))

        // With Reduce Motion, Toasty asks for no animation, and the shapes
        // rest in place.
        let still = UIHostingController(rootView: ToasttyLayerAnimationView(
            shapes: [.spinnerArc(size: 12, lineWidth: 1.5, color: .orange)], animates: false
        ).frame(width: 12, height: 12))
        window.rootViewController = still
        XCTAssertEqual(try layerView(in: still.view).playingAnimationKeys, [[]])

        // At rest, Toasty has no steam at all.
        let quiet = UIHostingController(rootView: Self.icon(.none))
        window.rootViewController = quiet
        pump()
        XCTAssertNil(find(ToasttyLayerAnimationUIView.self, in: quiet.view))
    }

    /// The spinner turns in Core Animation. As a SwiftUI animation it
    /// updated the window's whole view graph 24 times a second while any
    /// session worked, and typing in the composer lagged.
    func testSpinnerTurnsOutsideSwiftUIUpdates() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil }

        let spinner = UIHostingController(rootView: ToasttySpinner(size: 9).padding(20))
        window.rootViewController = spinner
        window.makeKeyAndVisible()
        let arc = try layerView(in: spinner.view)
        let rotation = [ToasttyLayerAnimationView.Animation.Property.rotation.rawValue]
        XCTAssertEqual(arc.playingAnimationKeys, [rotation])

        window.rootViewController = UIViewController()
        pump()
        window.rootViewController = spinner
        pump()
        XCTAssertEqual(arc.playingAnimationKeys, [rotation])
    }

    private static func icon(_ status: ToastyIcon.Status) -> some View {
        ToastyIcon(style: .golden, size: 17, status: status, palette: .phone, badgeRingColor: .black)
            .padding(20)
    }

    private func layerView(in view: UIView) throws -> ToasttyLayerAnimationUIView {
        view.layoutIfNeeded()
        pump()
        return try XCTUnwrap(find(ToasttyLayerAnimationUIView.self, in: view), "No Core Animation view")
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
}
