import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

@MainActor
final class TerminalHostViewSurfaceLifecycleTests: TerminalHostViewTestCase {
    func testResetTrackedGhosttyModifiersForApplicationDeactivationSendsSyntheticControlRelease() throws {
        let hostView = TerminalHostView()
        let keyRecorder = GhosttyKeyEventRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, keyEvent in
                keyRecorder.record(keyEvent)
                return true
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1234))

        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x3B,
                modifierFlags: [.control]
            )
        )

        let releasedCount = hostView.resetTrackedGhosttyModifiersForApplicationDeactivation()

        XCTAssertEqual(releasedCount, 1)
        XCTAssertEqual(
            keyRecorder.events.map(\.actionRawValue),
            [GHOSTTY_ACTION_PRESS.rawValue, GHOSTTY_ACTION_RELEASE.rawValue]
        )
        XCTAssertEqual(
            keyRecorder.events.map(\.keyCode),
            [UInt32(0x3B), UInt32(0x3B)]
        )
        XCTAssertEqual(keyRecorder.events.first?.modsRawValue, GHOSTTY_MODS_CTRL.rawValue)
        XCTAssertEqual(keyRecorder.events.last?.modsRawValue, GHOSTTY_MODS_NONE.rawValue)
    }

    func testResetTrackedGhosttyModifiersForApplicationDeactivationPreservesRemainingRightShiftState() throws {
        let hostView = TerminalHostView()
        let keyRecorder = GhosttyKeyEventRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, keyEvent in
                keyRecorder.record(keyEvent)
                return true
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1235))

        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x3C,
                modifierFlags: NSEvent.ModifierFlags(
                    rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
                )
            )
        )
        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x3B,
                modifierFlags: NSEvent.ModifierFlags.shift.union(.control)
            )
        )

        let releasedCount = hostView.resetTrackedGhosttyModifiersForApplicationDeactivation()

        XCTAssertEqual(releasedCount, 2)
        let syntheticReleases = Array(keyRecorder.events.suffix(2))
        XCTAssertEqual(
            syntheticReleases.map(\.keyCode),
            [UInt32(0x3B), UInt32(0x3C)]
        )
        XCTAssertEqual(
            syntheticReleases.map(\.modsRawValue),
            [
                GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_SHIFT_RIGHT.rawValue,
                GHOSTTY_MODS_NONE.rawValue,
            ]
        )
    }

    func testSetGhosttySurfaceReplacementDrainsTrackedModifiersFromPreviousSurface() throws {
        let hostView = TerminalHostView()
        let keyRecorder = GhosttyKeyEventRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, keyEvent in
                keyRecorder.record(keyEvent)
                return true
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1237))
        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x3B,
                modifierFlags: [.control]
            )
        )

        hostView.setGhosttySurface(fakeSurfaceHandle(0x1238))

        XCTAssertEqual(
            keyRecorder.events.map(\.actionRawValue),
            [GHOSTTY_ACTION_PRESS.rawValue, GHOSTTY_ACTION_RELEASE.rawValue]
        )
        XCTAssertEqual(
            keyRecorder.events.map(\.keyCode),
            [UInt32(0x3B), UInt32(0x3B)]
        )
        XCTAssertEqual(keyRecorder.events.last?.modsRawValue, GHOSTTY_MODS_NONE.rawValue)
        XCTAssertEqual(hostView.resetTrackedGhosttyModifiersForApplicationDeactivation(), 0)
    }

    func testResetTrackedGhosttyModifiersForApplicationDeactivationIsIdempotent() throws {
        let hostView = TerminalHostView()
        let keyRecorder = GhosttyKeyEventRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, keyEvent in
                keyRecorder.record(keyEvent)
                return true
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1236))
        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x3B,
                modifierFlags: [.control]
            )
        )

        XCTAssertEqual(hostView.resetTrackedGhosttyModifiersForApplicationDeactivation(), 1)
        let eventCountAfterFirstReset = keyRecorder.events.count

        XCTAssertEqual(hostView.resetTrackedGhosttyModifiersForApplicationDeactivation(), 0)
        XCTAssertEqual(keyRecorder.events.count, eventCountAfterFirstReset)
    }

    func testSetGhosttySurfaceSkipsRepeatedAssignmentForSameSurface() {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var requestCount = 0
        let focusHookCount = HookCallCounter()
        let occlusionHookCount = HookCallCounter()
        let refreshHookCount = HookCallCounter()
        let surface = fakeSurfaceHandle(0x1234)

        hostView.applicationIsActiveProvider = { true }
        hostView.requestFirstResponderIfNeeded = {
            requestCount += 1
        }
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in
                focusHookCount.increment()
            },
            setOcclusion: { _, _ in
                occlusionHookCount.increment()
            },
            refresh: { _ in
                refreshHookCount.increment()
            }
        )
        window.forcedOcclusionState = [.visible]
        window.forcedIsKeyWindow = true
        window.contentView = contentView

        contentView.addSubview(hostView)
        _ = hostView.synchronizePresentationVisibility(reason: "test_surface_assignment_visible")
        _ = window.makeFirstResponder(hostView)
        requestCount = 0

        hostView.setGhosttySurface(surface)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(focusHookCount.value, 1)
        XCTAssertEqual(occlusionHookCount.value, 1)
        XCTAssertEqual(refreshHookCount.value, 1)

        requestCount = 0
        hostView.setGhosttySurface(surface)
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(focusHookCount.value, 1)
        XCTAssertEqual(occlusionHookCount.value, 1)
        XCTAssertEqual(refreshHookCount.value, 1)
    }
}
#endif
