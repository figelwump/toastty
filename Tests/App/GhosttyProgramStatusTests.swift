import AppKit
import CoreState
import XCTest
@testable import ToasttyApp

#if TOASTTY_HAS_GHOSTTY_KIT
@MainActor
final class GhosttyProgramStatusTests: TerminalHostViewTestCase {
    func testImmediateChildExitPreservesCompletedStatus() throws {
        for state in [TerminalProgramStatusReport.State.done, .error] {
            let hostView = TerminalHostView()
            hostView.frame = CGRect(x: 0, y: 0, width: 640, height: 240)
            let window = attachToVisibleWindow(hostView)
            _ = window
            let manager = GhosttyRuntimeManager.shared
            let previousHandler = manager.actionHandler
            let handler = ProgramStatusHandler()
            manager.actionHandler = handler
            defer { manager.actionHandler = previousHandler }
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let fixture = root.appendingPathComponent("scripts/automation/program-status-fixture.py").path
            let input = "exec python3 '\(fixture.replacingOccurrences(of: "'", with: "'\\''"))' --scenario \(state.rawValue) --hold-seconds 0\n"
            let created = try XCTUnwrap(manager.makeSurface(
                hostView: hostView, workingDirectory: NSTemporaryDirectory(), fontPoints: 12,
                launchConfiguration: .init(initialInput: input)
            ))
            defer { manager.freeSurfaceForTesting(created.surface) }
            manager.setSurfaceSizeForTesting(created.surface, width: 640, height: 240)
            let deadline = Date(timeIntervalSinceNow: 30)
            while Date() < deadline {
                if handler.events.contains(.exit), handler.records.presentation?.record.state == state { break }
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            XCTAssertTrue(handler.events.contains(.exit))
            XCTAssertEqual(handler.records.presentation?.record.state, state)
        }
    }

    func testRealTerminalQueryReportsAndLifecycleReachOwnedSwiftValuesInOrder() throws {
        let hostView = TerminalHostView()
        hostView.frame = CGRect(x: 0, y: 0, width: 640, height: 240)
        let window = attachToVisibleWindow(hostView)
        _ = window
        let manager = GhosttyRuntimeManager.shared
        let previousHandler = manager.actionHandler
        let handler = ProgramStatusHandler()
        manager.actionHandler = handler
        defer { manager.actionHandler = previousHandler }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("scripts/automation/program-status-fixture.py").path
        let input = "python3 '\(fixture.replacingOccurrences(of: "'", with: "'\\''"))' --scenario lifecycle --hold-seconds 30\n"
        let created = try XCTUnwrap(manager.makeSurface(
            hostView: hostView, workingDirectory: NSTemporaryDirectory(), fontPoints: 12,
            launchConfiguration: .init(initialInput: input)
        ))
        defer { manager.freeSurfaceForTesting(created.surface) }
        manager.setSurfaceSizeForTesting(created.surface, width: 640, height: 240)
        let deadline = Date(timeIntervalSinceNow: 30)
        while !handler.events.contains(.report(.init(state: .done, app: "deploy", title: "Result", message: "Reset complete"))), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        let first = try XCTUnwrap(handler.events.firstIndex(of: .report(.init(state: .clear))))
        XCTAssertEqual(Array(handler.events.dropFirst(first).prefix(7)), [
            .report(.init(state: .clear)),
            .report(.init(state: .working, app: "deploy", title: "Deploy café", progress: 65)),
            .report(.init(state: .blocked, id: "west", title: "EU West", message: "Approve deployment?", kind: .permission)),
            .prompt,
            .report(.init(state: .done, message: "Complete")),
            .reset,
            .report(.init(state: .done, app: "deploy", title: "Result", message: "Reset complete")),
        ])
    }
}

@MainActor
private final class ProgramStatusHandler: GhosttyRuntimeActionHandling {
    var events: [TerminalProgramStatusEvent] = []
    var records = TerminalProgramStatusRecords()
    func handleGhosttyRuntimeAction(_ action: GhosttyRuntimeAction) -> Bool {
        guard case .programStatus(let event) = action.intent else { return false }
        events.append(event)
        records.apply(event)
        return true
    }
    func handleGhosttyCloseSurfaceRequest(surfaceHandle: UInt?, confirmed: Bool) -> Bool { false }
}
#endif
