import AppKit
import Carbon.HIToolbox
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// Command-plus, Command-minus and Command-zero in the coordinator's panel:
/// they change the chat's text while the chat shows, and the terminal's
/// font while the terminal shows.
@MainActor
struct CoordinatorChatTextSizeTests {
    @Test func textSizeKeysChangeTheChatWhileItCoversTheTerminal() throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        let keys = try Keys(fixture)
        let windowID = try #require(fixture.store.state.coordinator?.windowID)
        let terminalPoints = fixture.store.state.effectiveTerminalFontPoints(for: windowID)
        #expect(fixture.controller.coversTerminal(panelID: fixture.panelID))
        #expect(fixture.chat.textScale == 1)

        #expect(try keys.press(.increase) == .increaseTextSize)
        #expect(fixture.chat.textScale == 1.1)
        #expect(try keys.press(.decrease) == .decreaseTextSize)
        #expect(try keys.press(.decrease) == .decreaseTextSize)
        #expect(fixture.chat.textScale == 0.9)
        #expect(try keys.press(.reset) == .resetTextSize)
        #expect(fixture.chat.textScale == 1)
        // The terminal under the chat keeps its font.
        #expect(fixture.store.state.effectiveTerminalFontPoints(for: windowID) == terminalPoints)

        // The size stops at the largest and the smallest scale.
        for _ in 0..<20 { _ = try keys.press(.increase) }
        #expect(fixture.chat.textScale == CoordinatorChatModel.maximumTextScale)
        for _ in 0..<20 { _ = try keys.press(.decrease) }
        #expect(fixture.chat.textScale == CoordinatorChatModel.minimumTextScale)
        _ = try keys.press(.reset)

        // With the terminal shown, the keys change the terminal's font.
        fixture.controller.showsTerminal = true
        #expect(try keys.press(.increase) == .increaseTextSize)
        #expect(fixture.store.state.effectiveTerminalFontPoints(for: windowID) > terminalPoints)
        #expect(fixture.chat.textScale == 1)
    }

    @Test func theChatKeepsItsTextSizeAfterARelaunch() throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        let suiteName = "toastty-coordinator-text-size-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let access = fixture.conversations.service

        let first = CoordinatorChatModel(controller: fixture.controller, access: access, defaults: defaults)
        first.changeTextScale(.increase)
        first.changeTextScale(.increase)
        #expect(first.textScale == 1.2)
        #expect(CoordinatorChatModel(controller: fixture.controller, access: access, defaults: defaults).textScale == 1.2)

        // The default size saves nothing, and a later default reads as 1.
        first.changeTextScale(.reset)
        #expect(defaults.object(forKey: CoordinatorChatModel.textScaleDefaultsKey) == nil)
        #expect(CoordinatorChatModel(controller: fixture.controller, access: access, defaults: defaults).textScale == 1)

        // A saved value out of range is brought into range.
        defaults.set(9.0, forKey: CoordinatorChatModel.textScaleDefaultsKey)
        #expect(CoordinatorChatModel(controller: fixture.controller, access: access, defaults: defaults).textScale
            == CoordinatorChatModel.maximumTextScale)
    }

    /// The app's key handling for the coordinator's window, with the
    /// coordinator attached as the app attaches it.
    @MainActor
    private struct Keys {
        let interceptor: DisplayShortcutInterceptor
        let windowID: UUID
        let taskCoordinator: TaskCoordinator

        init(_ fixture: CoordinatorChatFixture) throws {
            let store = fixture.store
            let sessions = fixture.conversations.sessionRuntimeStore
            taskCoordinator = TaskCoordinator(
                records: TaskRecordStore.inMemory(),
                store: store,
                launcher: nil,
                configLoader: { TasksConfig() },
                attachmentsDirectoryURL: FileManager.default.temporaryDirectory,
                hasActiveSession: { _ in false },
                grantScope: { _, _ in }
            )
            taskCoordinator.coordinatorController = fixture.controller
            sessions.taskCoordinator = taskCoordinator
            windowID = try #require(store.state.coordinator?.windowID)
            let terminals = fixture.conversations.terminalRuntimeRegistry
            interceptor = DisplayShortcutInterceptor(
                store: store,
                terminalRuntimeRegistry: terminals,
                webPanelRuntimeRegistry: WebPanelRuntimeRegistry(),
                sessionRuntimeStore: sessions,
                focusedPanelCommandController: FocusedPanelCommandController(
                    store: store,
                    runtimeRegistry: terminals,
                    slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
                ),
                installEventMonitor: false
            )
        }

        enum Key {
            case increase, decrease, reset
        }

        /// Presses the key and returns the action the app took for it.
        func press(_ key: Key) throws -> DisplayShortcutInterceptor.ShortcutAction? {
            let (characters, keyCode): (String, Int) = switch key {
            case .increase: ("=", kVK_ANSI_Equal)
            case .decrease: ("-", kVK_ANSI_Minus)
            case .reset: ("0", kVK_ANSI_0)
            }
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: UInt16(keyCode)
            ))
            let action = interceptor.shortcutAction(for: event, appOwnedWindowID: windowID)
            if let action {
                #expect(interceptor.handle(action, appOwnedWindowID: windowID))
            }
            return action
        }
    }
}
