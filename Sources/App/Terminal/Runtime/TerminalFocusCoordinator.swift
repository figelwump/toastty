import AppKit
import Foundation

@MainActor
final class TerminalFocusCoordinator {
    struct FocusTarget {
        let isReadyForFocus: Bool
        let focusHostViewIfNeeded: () -> Bool
    }

    private let maxAttempts: Int
    private let retryDelayNanoseconds: UInt64
    private let isApplicationActive: () -> Bool
    private let shouldAvoidStealingKeyboardFocus: () -> Bool
    private var selectedSlotFocusRestoreTask: Task<Void, Never>?

    convenience init() {
        self.init(
            maxAttempts: 12,
            retryDelayNanoseconds: 16_000_000,
            isApplicationActive: { NSApp.isActive },
            shouldAvoidStealingKeyboardFocus: {
                guard let keyWindow = NSApp.keyWindow,
                      let textView = keyWindow.firstResponder as? NSTextView else {
                    return false
                }
                return textView.isFieldEditor
            }
        )
    }

    init(
        maxAttempts: Int,
        retryDelayNanoseconds: UInt64,
        isApplicationActive: @escaping () -> Bool,
        shouldAvoidStealingKeyboardFocus: @escaping () -> Bool
    ) {
        self.maxAttempts = maxAttempts
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.isApplicationActive = isApplicationActive
        self.shouldAvoidStealingKeyboardFocus = shouldAvoidStealingKeyboardFocus
    }

    deinit {
        selectedSlotFocusRestoreTask?.cancel()
    }

    @discardableResult
    func focusSelectedWorkspaceSlotIfPossible(
        resolveSelectedFocusTarget: () -> FocusTarget?
    ) -> Bool {
        guard let focusTarget = resolveSelectedFocusTarget(),
              focusTarget.isReadyForFocus else {
            return false
        }
        return focusTarget.focusHostViewIfNeeded()
    }

    func scheduleSelectedWorkspaceSlotFocusRestore(
        avoidStealingKeyboardFocus: Bool = true,
        attemptRestoreFocus: @escaping @MainActor () -> Bool
    ) {
        selectedSlotFocusRestoreTask?.cancel()
        selectedSlotFocusRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for attempt in 0..<self.maxAttempts {
                guard Task.isCancelled == false else { return }
                if self.isApplicationActive(),
                   avoidStealingKeyboardFocus,
                   self.shouldAvoidStealingKeyboardFocus() {
                    return
                }
                if self.isApplicationActive(), attemptRestoreFocus() {
                    return
                }
                guard attempt < self.maxAttempts - 1 else { return }
                try? await Task.sleep(nanoseconds: self.retryDelayNanoseconds)
                guard Task.isCancelled == false else { return }
            }
        }
    }
}
