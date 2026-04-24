import AppKit
import CoreState
import SwiftUI

struct AppWindowSceneObserver: NSViewRepresentable {
    let windowID: UUID
    let desiredFrame: CGRectCodable?
    let windowTitle: String?
    let shouldConfirmWindowClose: Bool
    let onWindowDidBecomeKey: @MainActor () -> Void
    let onWindowFrameChange: @MainActor (CGRectCodable) -> Void
    let onWindowCloseInitiated: @MainActor () -> Void
    let onWindowWillClose: @MainActor () -> Void

    func makeCoordinator() -> AppWindowSceneObserverCoordinator {
        AppWindowSceneObserverCoordinator(
            windowID: windowID,
            windowTitle: windowTitle,
            onWindowDidBecomeKey: onWindowDidBecomeKey,
            onWindowFrameChange: onWindowFrameChange,
            onWindowCloseInitiated: onWindowCloseInitiated,
            onWindowWillClose: onWindowWillClose,
            shouldConfirmWindowClose: shouldConfirmWindowClose
        )
    }

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onWindowChange = { window in
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowTrackingView, context: Context) {
        context.coordinator.windowID = windowID
        context.coordinator.desiredFrame = desiredFrame?.cgRect
        context.coordinator.windowTitle = windowTitle
        context.coordinator.shouldConfirmWindowClose = shouldConfirmWindowClose
        context.coordinator.onWindowDidBecomeKey = onWindowDidBecomeKey
        context.coordinator.onWindowFrameChange = onWindowFrameChange
        context.coordinator.onWindowCloseInitiated = onWindowCloseInitiated
        context.coordinator.onWindowWillClose = onWindowWillClose
        context.coordinator.attach(to: nsView.window)
        context.coordinator.applyDesiredFrameIfNeeded(clampToVisibleScreens: false)
        // attach(to:) handles the first window binding; keep reapplying here so
        // workspace selection and rename changes update the already attached window.
        context.coordinator.applyWindowTitleIfNeeded()
        context.coordinator.installNativeCloseButtonOverrideIfNeeded()
    }

    static func dismantleNSView(_ nsView: WindowTrackingView, coordinator: AppWindowSceneObserverCoordinator) {
        coordinator.detach()
        nsView.onWindowChange = nil
    }
}

final class WindowTrackingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

@MainActor
final class AppWindowSceneObserverCoordinator: NSObject {
    typealias MainActorScheduler = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    typealias WindowTitleProvider = @Sendable () -> String
    typealias VisibleScreenFramesProvider = @Sendable () -> [CGRect]
    typealias WindowCloseConfirmationPresenter = @MainActor (
        _ window: NSWindow,
        _ completion: @escaping @MainActor (Bool) -> Void
    ) -> Void
    typealias WindowCloser = @MainActor (NSWindow) -> Void

    var windowID: UUID
    var desiredFrame: CGRect?
    var windowTitle: String?
    var onWindowDidBecomeKey: @MainActor () -> Void
    var onWindowFrameChange: @MainActor (CGRectCodable) -> Void
    var onWindowCloseInitiated: @MainActor () -> Void
    var onWindowWillClose: @MainActor () -> Void

    private weak var observedWindow: NSWindow?
    private var observerTokens: [NSObjectProtocol] = []
    private var lastPublishedWindowFrame: CGRect?
    private let scheduleOnMainActor: MainActorScheduler
    private let defaultWindowTitle: WindowTitleProvider
    private let screenVisibleFramesProvider: VisibleScreenFramesProvider
    var shouldConfirmWindowClose: Bool
    private let presentWindowCloseConfirmation: WindowCloseConfirmationPresenter
    private let closeWindow: WindowCloser
    private var isPresentingWindowCloseConfirmation = false

    init(
        windowID: UUID,
        windowTitle: String? = nil,
        onWindowDidBecomeKey: @escaping @MainActor () -> Void,
        onWindowFrameChange: @escaping @MainActor (CGRectCodable) -> Void,
        onWindowCloseInitiated: @escaping @MainActor () -> Void = {},
        onWindowWillClose: @escaping @MainActor () -> Void,
        shouldConfirmWindowClose: Bool = !AutomationConfig.shouldBypassInteractiveConfirmation(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        ),
        presentWindowCloseConfirmation: @escaping WindowCloseConfirmationPresenter = {
            window,
            completion in
            AppWindowSceneObserverCoordinator.presentWindowCloseConfirmation(
                window: window,
                completion: completion
            )
        },
        closeWindow: @escaping WindowCloser = { window in
            window.close()
        },
        defaultWindowTitle: @escaping WindowTitleProvider = {
            AppWindowSceneObserverCoordinator.resolveDefaultWindowTitle(from: .main)
        },
        screenVisibleFramesProvider: @escaping VisibleScreenFramesProvider = {
            NSScreen.screens.map(\.visibleFrame)
        },
        scheduleOnMainActor: @escaping MainActorScheduler = { operation in
            // Hop to the next MainActor turn so scene/window callbacks triggered
            // during updateNSView don't synchronously publish AppStore changes
            // inside SwiftUI's view update transaction.
            Task { @MainActor in
                operation()
            }
        }
    ) {
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.onWindowDidBecomeKey = onWindowDidBecomeKey
        self.onWindowFrameChange = onWindowFrameChange
        self.onWindowCloseInitiated = onWindowCloseInitiated
        self.onWindowWillClose = onWindowWillClose
        self.shouldConfirmWindowClose = shouldConfirmWindowClose
        self.presentWindowCloseConfirmation = presentWindowCloseConfirmation
        self.closeWindow = closeWindow
        self.defaultWindowTitle = defaultWindowTitle
        self.screenVisibleFramesProvider = screenVisibleFramesProvider
        self.scheduleOnMainActor = scheduleOnMainActor
        super.init()
    }

    func attach(to window: NSWindow?) {
        guard observedWindow !== window else { return }

        detach()
        observedWindow = window

        guard let window else { return }
        let expectedIdentifier = NSUserInterfaceItemIdentifier(windowID.uuidString)
        if window.identifier != expectedIdentifier {
            window.identifier = expectedIdentifier
        }
        installNativeCloseButtonOverrideIfNeeded()
        applyWindowTitleIfNeeded()
        let notificationCenter = NotificationCenter.default
        let scheduleOnMainActor = self.scheduleOnMainActor

        observerTokens.append(
            notificationCenter.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                scheduleOnMainActor { [weak self] in
                    self?.onWindowDidBecomeKey()
                }
            }
        )
        observerTokens.append(
            notificationCenter.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                scheduleOnMainActor { [weak self] in
                    self?.publishWindowFrame()
                }
            }
        )
        observerTokens.append(
            notificationCenter.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                scheduleOnMainActor { [weak self] in
                    self?.publishWindowFrame()
                }
            }
        )
        observerTokens.append(
            notificationCenter.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                scheduleOnMainActor { [weak self] in
                    self?.onWindowWillClose()
                }
            }
        )
        observerTokens.append(
            notificationCenter.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                scheduleOnMainActor { [weak self] in
                    self?.installNativeCloseButtonOverrideIfNeeded()
                }
            }
        )
        observerTokens.append(
            notificationCenter.addObserver(
                forName: NSWindow.didDeminiaturizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                scheduleOnMainActor { [weak self] in
                    self?.installNativeCloseButtonOverrideIfNeeded()
                }
            }
        )
        observerTokens.append(
            notificationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                scheduleOnMainActor { [weak self] in
                    self?.clampObservedWindowFrameToVisibleScreensIfNeeded()
                }
            }
        )

        applyDesiredFrameIfNeeded(clampToVisibleScreens: true)

        if window.isKeyWindow {
            scheduleOnMainActor { [weak self] in
                self?.onWindowDidBecomeKey()
            }
        }
    }

    func detach() {
        let notificationCenter = NotificationCenter.default
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
        lastPublishedWindowFrame = nil
        isPresentingWindowCloseConfirmation = false
        observedWindow = nil
    }

    func installNativeCloseButtonOverrideIfNeeded() {
        guard let closeButton = observedWindow?.standardWindowButton(.closeButton) else { return }
        guard closeButton.target !== self ||
            closeButton.action != #selector(handleNativeCloseButton(_:)) else {
            return
        }

        // Cmd+W and File > Close stay on Toastty's panel-close paths. The red
        // traffic-light button is app-owned so Toastty can confirm destructive
        // whole-window teardown before allowing AppKit to close the window.
        closeButton.target = self
        closeButton.action = #selector(handleNativeCloseButton(_:))
    }

    func applyDesiredFrameIfNeeded(clampToVisibleScreens: Bool = false) {
        guard let observedWindow, let desiredFrame else { return }
        // Preserve the live-drag suppression from raw AppKit frames before any
        // display-aware clamping. Straddling two screens is valid while the user
        // drags, even if the eventual settled frame would be clamped later.
        if let lastPublishedWindowFrame,
           framesEqual(lastPublishedWindowFrame, desiredFrame) {
            return
        }
        let shouldClampToVisibleScreens = clampToVisibleScreens || lastPublishedWindowFrame == nil
        let resolvedDesiredFrame = shouldClampToVisibleScreens ? adjustedFrameForVisibleScreens(desiredFrame) : desiredFrame
        guard framesEqual(observedWindow.frame, resolvedDesiredFrame) == false else { return }
        // Window move/resize notifications publish the live AppKit frame back
        // into app state. Ignore that immediate state echo so SwiftUI updates do
        // not replay a stale frame onto an actively dragged window.
        observedWindow.setFrame(resolvedDesiredFrame, display: true)
    }

    func applyWindowTitleIfNeeded() {
        guard let observedWindow else { return }

        // Hidden-titlebar windows still use NSWindow.title for window cycling and previews.
        let resolvedTitle = normalizedWindowTitle ?? defaultWindowTitle()
        guard observedWindow.title != resolvedTitle else { return }
        observedWindow.title = resolvedTitle
    }

    private func publishWindowFrame() {
        guard let observedWindow else { return }
        let frame = observedWindow.frame
        lastPublishedWindowFrame = frame
        onWindowFrameChange(CGRectCodable(frame))
    }

    private func clampObservedWindowFrameToVisibleScreensIfNeeded() {
        guard let observedWindow else { return }
        let adjustedFrame = adjustedFrameForVisibleScreens(observedWindow.frame)
        guard framesEqual(observedWindow.frame, adjustedFrame) == false else { return }
        observedWindow.setFrame(adjustedFrame, display: true)
    }

    @objc
    private func handleNativeCloseButton(_ sender: Any?) {
        guard let observedWindow else { return }
        guard shouldConfirmWindowClose else {
            onWindowCloseInitiated()
            closeWindow(observedWindow)
            return
        }
        guard isPresentingWindowCloseConfirmation == false else {
            return
        }

        isPresentingWindowCloseConfirmation = true
        presentWindowCloseConfirmation(observedWindow) { [weak self, weak observedWindow] didConfirm in
            guard let self else { return }
            self.isPresentingWindowCloseConfirmation = false
            guard didConfirm, let observedWindow else { return }
            self.onWindowCloseInitiated()
            self.closeWindow(observedWindow)
        }
    }

    private var normalizedWindowTitle: String? {
        guard let windowTitle else { return nil }
        let trimmedTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else { return nil }
        return trimmedTitle
    }

    private func framesEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5 &&
            abs(lhs.origin.y - rhs.origin.y) < 0.5 &&
            abs(lhs.size.width - rhs.size.width) < 0.5 &&
            abs(lhs.size.height - rhs.size.height) < 0.5
    }

    private func adjustedFrameForVisibleScreens(_ frame: CGRect) -> CGRect {
        let visibleFrames = screenVisibleFramesProvider().filter { $0.isEmpty == false && $0.isNull == false }
        guard let targetVisibleFrame = bestVisibleFrame(for: frame, visibleFrames: visibleFrames) else {
            return frame
        }

        // Keep the window fully reachable on the most relevant remaining screen
        // after monitor unplug/rearrange events or when restoring stale frames.
        let adjustedWidth = min(max(frame.width, 1), targetVisibleFrame.width)
        let adjustedHeight = min(max(frame.height, 1), targetVisibleFrame.height)
        let adjustedX = clampedValue(
            frame.origin.x,
            minimum: targetVisibleFrame.minX,
            maximum: targetVisibleFrame.maxX - adjustedWidth
        )
        let adjustedY = clampedValue(
            frame.origin.y,
            minimum: targetVisibleFrame.minY,
            maximum: targetVisibleFrame.maxY - adjustedHeight
        )

        return CGRect(
            x: adjustedX,
            y: adjustedY,
            width: adjustedWidth,
            height: adjustedHeight
        )
    }

    private func bestVisibleFrame(for frame: CGRect, visibleFrames: [CGRect]) -> CGRect? {
        let frameCenter = CGPoint(x: frame.midX, y: frame.midY)
        return visibleFrames.max { lhs, rhs in
            let lhsIntersectionArea = intersectionArea(between: frame, and: lhs)
            let rhsIntersectionArea = intersectionArea(between: frame, and: rhs)
            if abs(lhsIntersectionArea - rhsIntersectionArea) >= 0.5 {
                return lhsIntersectionArea < rhsIntersectionArea
            }

            let lhsDistance = squaredDistance(from: frameCenter, to: lhs)
            let rhsDistance = squaredDistance(from: frameCenter, to: rhs)
            if abs(lhsDistance - rhsDistance) >= 0.5 {
                return lhsDistance > rhsDistance
            }

            let lhsArea = lhs.width * lhs.height
            let rhsArea = rhs.width * rhs.height
            return lhsArea < rhsArea
        }
    }

    private func intersectionArea(between lhs: CGRect, and rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        guard intersection.isNull == false, intersection.isEmpty == false else {
            return 0
        }
        return intersection.width * intersection.height
    }

    private func squaredDistance(from point: CGPoint, to rect: CGRect) -> Double {
        let closestX = clampedValue(point.x, minimum: rect.minX, maximum: rect.maxX)
        let closestY = clampedValue(point.y, minimum: rect.minY, maximum: rect.maxY)
        let deltaX = point.x - closestX
        let deltaY = point.y - closestY
        return deltaX * deltaX + deltaY * deltaY
    }

    private func clampedValue(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }

    nonisolated private static func resolveDefaultWindowTitle(from bundle: Bundle) -> String {
        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedDisplayName.isEmpty == false {
                return trimmedDisplayName
            }
        }

        if let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            let trimmedBundleName = bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBundleName.isEmpty == false {
                return trimmedBundleName
            }
        }

        let bundleFileName = bundle.bundleURL
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if bundleFileName.isEmpty == false {
            return bundleFileName
        }

        let processName = ProcessInfo.processInfo.processName.trimmingCharacters(in: .whitespacesAndNewlines)
        if processName.isEmpty == false {
            return processName
        }

        return "App"
    }

    @MainActor
    private static func presentWindowCloseConfirmation(
        window: NSWindow,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Close this window?"
        alert.informativeText = """
        Closing this window will close all terminals, tabs, and workspaces in this window.
        """
        alert.alertStyle = .warning
        alert.addConfiguredButton(withTitle: "Cancel", behavior: .cancelAction)
        alert.addConfiguredButton(
            withTitle: "Close Window",
            behavior: .defaultAction
        )
        alert.beginSheetModal(for: window) { response in
            Task { @MainActor in
                completion(response == .alertSecondButtonReturn)
            }
        }
    }
}
