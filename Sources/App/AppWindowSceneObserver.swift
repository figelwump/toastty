import AppKit
import CoreState
import SwiftUI

struct AppWindowSceneObserver: NSViewRepresentable {
    let windowID: UUID
    let desiredFrame: CGRectCodable?
    let windowTitle: String?
    let onWindowDidBecomeKey: @MainActor () -> Void
    let onWindowFrameChange: @MainActor (CGRectCodable) -> Void
    let onWindowWillClose: @MainActor () -> Void

    func makeCoordinator() -> AppWindowSceneObserverCoordinator {
        AppWindowSceneObserverCoordinator(
            windowID: windowID,
            windowTitle: windowTitle,
            onWindowDidBecomeKey: onWindowDidBecomeKey,
            onWindowFrameChange: onWindowFrameChange,
            onWindowWillClose: onWindowWillClose
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
        context.coordinator.onWindowDidBecomeKey = onWindowDidBecomeKey
        context.coordinator.onWindowFrameChange = onWindowFrameChange
        context.coordinator.onWindowWillClose = onWindowWillClose
        context.coordinator.attach(to: nsView.window)
        context.coordinator.applyDesiredFrameIfNeeded()
        // attach(to:) handles the first window binding; keep reapplying here so
        // workspace selection and rename changes update the already attached window.
        context.coordinator.applyWindowTitleIfNeeded()
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

    var windowID: UUID
    var desiredFrame: CGRect?
    var windowTitle: String?
    var onWindowDidBecomeKey: @MainActor () -> Void
    var onWindowFrameChange: @MainActor (CGRectCodable) -> Void
    var onWindowWillClose: @MainActor () -> Void

    private weak var observedWindow: NSWindow?
    private var observerTokens: [NSObjectProtocol] = []
    private let scheduleOnMainActor: MainActorScheduler
    private let defaultWindowTitle: WindowTitleProvider

    init(
        windowID: UUID,
        windowTitle: String? = nil,
        onWindowDidBecomeKey: @escaping @MainActor () -> Void,
        onWindowFrameChange: @escaping @MainActor (CGRectCodable) -> Void,
        onWindowWillClose: @escaping @MainActor () -> Void,
        defaultWindowTitle: @escaping WindowTitleProvider = {
            AppWindowSceneObserverCoordinator.resolveDefaultWindowTitle(from: .main)
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
        self.onWindowWillClose = onWindowWillClose
        self.defaultWindowTitle = defaultWindowTitle
        self.scheduleOnMainActor = scheduleOnMainActor
        super.init()
    }

    func attach(to window: NSWindow?) {
        guard observedWindow !== window else { return }

        detach()
        observedWindow = window

        guard let window else { return }
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

        applyDesiredFrameIfNeeded()

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
        observedWindow = nil
    }

    func applyDesiredFrameIfNeeded() {
        guard let observedWindow, let desiredFrame else { return }
        guard framesEqual(observedWindow.frame, desiredFrame) == false else { return }
        observedWindow.setFrame(desiredFrame, display: true)
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
        onWindowFrameChange(CGRectCodable(observedWindow.frame))
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
}
