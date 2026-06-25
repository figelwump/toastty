import AppKit
import SwiftUI

struct ModifierKeyPressObserver: NSViewRepresentable {
    let modifier: NSEvent.ModifierFlags
    @Binding var isPressed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(modifier: modifier, isPressed: $isPressed)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(modifier: modifier, isPressed: $isPressed)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private var modifier: NSEvent.ModifierFlags
        private var isPressed: Binding<Bool>
        private var localMonitor: Any?
        private var notificationObservers: [NSObjectProtocol] = []

        init(modifier: NSEvent.ModifierFlags, isPressed: Binding<Bool>) {
            self.modifier = modifier
            self.isPressed = isPressed
        }

        func update(modifier: NSEvent.ModifierFlags, isPressed: Binding<Bool>) {
            self.modifier = modifier
            self.isPressed = isPressed
        }

        func start() {
            guard localMonitor == nil else { return }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                let flags = event.modifierFlags
                MainActor.assumeIsolated {
                    self?.updatePressedState(from: flags)
                }
                return event
            }

            let center = NotificationCenter.default
            notificationObservers.append(
                center.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.setPressed(false)
                    }
                }
            )
            notificationObservers.append(
                center.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updatePressedState(from: NSEvent.modifierFlags)
                    }
                }
            )
        }

        func stop() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
            for observer in notificationObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            notificationObservers.removeAll()
        }

        private func updatePressedState(from flags: NSEvent.ModifierFlags) {
            setPressed(flags.intersection(.deviceIndependentFlagsMask).contains(modifier))
        }

        private func setPressed(_ pressed: Bool) {
            guard isPressed.wrappedValue != pressed else { return }
            isPressed.wrappedValue = pressed
        }
    }
}
