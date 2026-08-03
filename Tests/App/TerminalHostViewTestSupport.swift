import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

class TerminalHostViewTestCase: XCTestCase {
    func fakeSurfaceHandle(_ rawValue: UInt) -> ghostty_surface_t {
        guard let surface = ghostty_surface_t(bitPattern: rawValue) else {
            fatalError("expected fake Ghostty surface handle")
        }
        return surface
    }

    @MainActor
    func makeMouseEvent(
        type: NSEvent.EventType,
        window: NSWindow,
        location: NSPoint = NSPoint(x: 12, y: 12),
        modifierFlags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        if type == .mouseEntered || type == .mouseExited {
            guard let event = NSEvent.enterExitEvent(
                with: type,
                location: location,
                modifierFlags: modifierFlags,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            ) else {
                throw NSError(domain: "TerminalHostViewTests", code: 1, userInfo: nil)
            }
            return event
        }

        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            throw NSError(domain: "TerminalHostViewTests", code: 1, userInfo: nil)
        }
        return event
    }

    @MainActor
    func attachToVisibleWindow(_ view: NSView) -> TestWindow {
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        window.forcedOcclusionState = [.visible]
        window.contentView = contentView
        contentView.addSubview(view)
        return window
    }

    func makeKeyEvent(
        type: NSEvent.EventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        characters: String = "",
        charactersIgnoringModifiers: String = ""
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            throw NSError(domain: "TerminalHostViewTests", code: 2, userInfo: nil)
        }
        return event
    }

    struct RecordedGhosttyKeyEvent: Equatable {
        let actionRawValue: UInt32
        let modsRawValue: UInt32
        let keyCode: UInt32
        let text: String?
        let composing: Bool
    }

    struct RecordedGhosttyMousePosition: Equatable {
        let surfaceRawValue: UInt?
        let x: Double
        let y: Double
        let modsRawValue: UInt32
    }

    struct RecordedGhosttyMouseButton: Equatable {
        let surfaceRawValue: UInt
        let stateRawValue: UInt32
        let buttonRawValue: UInt32
        let modsRawValue: UInt32
    }

    struct RecordedGhosttyMousePressure: Equatable {
        let surfaceRawValue: UInt
        let stage: UInt32
        let pressure: Double
    }

    final class GhosttyKeyEventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [RecordedGhosttyKeyEvent] = []

        func record(_ keyEvent: ghostty_input_key_s) {
            lock.lock()
            storage.append(
                RecordedGhosttyKeyEvent(
                    actionRawValue: keyEvent.action.rawValue,
                    modsRawValue: keyEvent.mods.rawValue,
                    keyCode: keyEvent.keycode,
                    text: keyEvent.text.flatMap { String(cString: $0) },
                    composing: keyEvent.composing
                )
            )
            lock.unlock()
        }

        var events: [RecordedGhosttyKeyEvent] {
            lock.lock()
            defer {
                lock.unlock()
            }
            return storage
        }
    }

    final class GhosttyMousePositionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [RecordedGhosttyMousePosition] = []

        func record(x: Double, y: Double, mods: ghostty_input_mods_e) {
            record(surface: nil, x: x, y: y, mods: mods)
        }

        func record(surface: ghostty_surface_t?, x: Double, y: Double, mods: ghostty_input_mods_e) {
            lock.lock()
            storage.append(
                RecordedGhosttyMousePosition(
                    surfaceRawValue: surface.map { UInt(bitPattern: $0) },
                    x: x,
                    y: y,
                    modsRawValue: mods.rawValue
                )
            )
            lock.unlock()
        }

        var lastEvent: RecordedGhosttyMousePosition? {
            lock.lock()
            defer {
                lock.unlock()
            }
            return storage.last
        }

        var events: [RecordedGhosttyMousePosition] {
            lock.lock()
            defer {
                lock.unlock()
            }
            return storage
        }
    }

    final class GhosttyMouseButtonRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [RecordedGhosttyMouseButton] = []

        func record(
            surface: ghostty_surface_t,
            state: ghostty_input_mouse_state_e,
            button: ghostty_input_mouse_button_e,
            mods: ghostty_input_mods_e
        ) {
            lock.lock()
            storage.append(
                RecordedGhosttyMouseButton(
                    surfaceRawValue: UInt(bitPattern: surface),
                    stateRawValue: state.rawValue,
                    buttonRawValue: button.rawValue,
                    modsRawValue: mods.rawValue
                )
            )
            lock.unlock()
        }

        var events: [RecordedGhosttyMouseButton] {
            lock.lock()
            defer {
                lock.unlock()
            }
            return storage
        }
    }

    final class GhosttyMousePressureRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [RecordedGhosttyMousePressure] = []

        func record(surface: ghostty_surface_t, stage: UInt32, pressure: Double) {
            lock.lock()
            storage.append(
                RecordedGhosttyMousePressure(
                    surfaceRawValue: UInt(bitPattern: surface),
                    stage: stage,
                    pressure: pressure
                )
            )
            lock.unlock()
        }

        var events: [RecordedGhosttyMousePressure] {
            lock.lock()
            defer {
                lock.unlock()
            }
            return storage
        }
    }

    final class SendableBooleanBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool

        init(_ value: Bool) {
            self.value = value
        }

        func takeIfTrue() -> Bool {
            lock.lock()
            defer {
                lock.unlock()
            }
            guard value else {
                return false
            }
            value = false
            return true
        }
    }

    final class SendableIntBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: Int

        init(_ value: Int) {
            self.storedValue = value
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }

        func increment() {
            lock.lock()
            storedValue += 1
            lock.unlock()
        }
    }

    final class GhosttyPreeditRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String?] = []

        func record(_ text: UnsafePointer<CChar>?, length: uintptr_t) {
            lock.lock()
            if let text {
                let bytePointer = UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self)
                let buffer = UnsafeBufferPointer(start: bytePointer, count: Int(length))
                storage.append(String(decoding: buffer, as: UTF8.self))
            } else {
                storage.append(nil)
            }
            lock.unlock()
        }

        var values: [String?] {
            lock.lock()
            defer {
                lock.unlock()
            }
            return storage
        }
    }

    final class GhosttyTextRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func record(_ text: UnsafePointer<CChar>, length: uintptr_t) {
            lock.lock()
            let bytePointer = UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self)
            let buffer = UnsafeBufferPointer(start: bytePointer, count: Int(length))
            storage.append(String(decoding: buffer, as: UTF8.self))
            lock.unlock()
        }

        var values: [String] {
            lock.lock()
            defer {
                lock.unlock()
            }
            return storage
        }
    }

    final class HookCallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer {
                lock.unlock()
            }
            return storage
        }
    }

    final class TestDraggingInfo: NSObject, NSDraggingInfo {
        private let pasteboard: NSPasteboard
        var numberOfValidItemsForDrop = 0
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false

        init(pasteboard: NSPasteboard) {
            self.pasteboard = pasteboard
        }

        var draggingPasteboard: NSPasteboard {
            pasteboard
        }

        var draggingDestinationWindow: NSWindow? {
            nil
        }

        var draggingSourceOperationMask: NSDragOperation {
            .copy
        }

        var draggingLocation: NSPoint {
            .zero
        }

        var draggedImageLocation: NSPoint {
            .zero
        }

        var draggedImage: NSImage? {
            NSImage(size: .zero)
        }

        var draggingSource: Any? {
            nil
        }

        var draggingSequenceNumber: Int {
            0
        }

        var springLoadingHighlight: NSSpringLoadingHighlight {
            .none
        }

        func slideDraggedImage(to screenPoint: NSPoint) {
            _ = screenPoint
        }

        func resetSpringLoading() {}

        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [],
            for view: NSView?,
            classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {
            _ = enumOpts
            _ = view
            _ = classArray
            _ = searchOptions
            _ = block
        }
    }

    final class TestWindow: NSWindow {
        var forcedOcclusionState: NSWindow.OcclusionState = []
        var forcedIsKeyWindow = false
        var forcedMouseLocationOutsideOfEventStream = NSPoint.zero
        private var storedFirstResponder: NSResponder?

        override var firstResponder: NSResponder? {
            storedFirstResponder
        }

        override var isKeyWindow: Bool {
            forcedIsKeyWindow
        }

        init() {
            super.init(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
        }

        override var occlusionState: NSWindow.OcclusionState {
            forcedOcclusionState
        }

        override var mouseLocationOutsideOfEventStream: NSPoint {
            forcedMouseLocationOutsideOfEventStream
        }

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            if let responder, responder.acceptsFirstResponder == false {
                return false
            }
            storedFirstResponder = responder
            return true
        }
    }

    final class MouseEventRecordingResponder: NSResponder {
        private(set) var mouseDownCount = 0
        private(set) var mouseUpCount = 0
        private(set) var rightMouseUpCount = 0

        override func mouseDown(with event: NSEvent) {
            _ = event
            mouseDownCount += 1
        }

        override func mouseUp(with event: NSEvent) {
            _ = event
            mouseUpCount += 1
        }

        override func rightMouseUp(with event: NSEvent) {
            _ = event
            rightMouseUpCount += 1
        }
    }

    final class FocusableTestView: NSView {
        override var acceptsFirstResponder: Bool {
            true
        }
    }
}
#endif
