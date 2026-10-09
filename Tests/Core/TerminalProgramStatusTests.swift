import Foundation
import Testing
@testable import CoreState

// Failure modes: partial replacement retains stale fields; clearing a prefix
// removes a sibling; orphan children lose inherited app identity; eviction is
// unbounded or ignores updates; prompt/reset/acknowledgement erase the wrong
// states; presentation hides a blocked child or invents combined progress.
struct TerminalProgramStatusTests {
    @Test
    func reportsReplaceAllFieldsAndKeepChildren() {
        var records = TerminalProgramStatusRecords()
        records.apply(.report(.init(state: .working, app: "deploy", title: "Release", message: "Uploading", progress: 65)))
        records.apply(.report(.init(state: .working, id: "west", progress: 30)))
        records.apply(.report(.init(state: .idle)))
        #expect(records.records[""] == .init(state: .idle))
        #expect(records.records["west"]?.progress == 30)
        #expect(records.presentation?.app == nil)
    }

    @Test
    func clearRemovesOnlyTheNamedSubtree() {
        var records = TerminalProgramStatusRecords()
        for id in ["", "build", "build/test", "build/test/unit", "builder", "build2/test", "other"] {
            records.apply(.report(.init(state: .working, id: id.isEmpty ? nil : id)))
        }
        records.apply(.report(.init(state: .clear, id: "build")))
        #expect(Set(records.records.keys) == ["", "builder", "build2/test", "other"])
        records.apply(.report(.init(state: .clear)))
        #expect(records.records.isEmpty)
        #expect(records.presentation == nil)
    }

    @Test
    func childInheritsNearestExistingAppAndReplacementRemovesInheritance() {
        var records = TerminalProgramStatusRecords()
        records.apply(.report(.init(state: .working, app: "deploy")))
        records.apply(.report(.init(state: .working, id: "west", app: "terraform")))
        records.apply(.report(.init(state: .blocked, id: "west/plan/approve", kind: .permission)))
        #expect(records.presentation?.app == "terraform")
        records.apply(.report(.init(state: .idle, id: "west")))
        #expect(records.presentation?.app == "deploy")
        records.apply(.report(.init(state: .idle)))
        #expect(records.presentation?.app == nil)
    }

    @Test
    func urgentChildWinsButRootTitleAndExplicitProgressArePreserved() {
        var records = TerminalProgramStatusRecords()
        records.apply(.report(.init(state: .working, app: "deploy", title: "Deploy v2.4.1", progress: 65)))
        records.apply(.report(.init(state: .working, id: "east", progress: 80)))
        records.apply(.report(.init(state: .blocked, id: "west", title: "EU West", message: "Approve deployment?", kind: .permission, progress: 30)))
        #expect(records.presentation?.record.id == "west")
        #expect(records.presentation?.rootTitle == "Deploy v2.4.1")
        #expect(records.presentation?.record.progress == 30)
        records.apply(.report(.init(state: .clear, id: "west")))
        #expect(records.presentation?.record.id == nil)
        #expect(records.presentation?.record.progress == 65)
    }

    @Test
    func severityThenRootThenRecencyDetermineTheOneRow() {
        var records = TerminalProgramStatusRecords()
        records.apply(.report(.init(state: .done)))
        records.apply(.report(.init(state: .working, id: "busy")))
        records.apply(.report(.init(state: .error, id: "failed")))
        records.apply(.report(.init(state: .blocked, id: "a", kind: .question)))
        records.apply(.report(.init(state: .blocked, id: "b", kind: .auth)))
        #expect(records.presentation?.record.id == "b")
        records.apply(.report(.init(state: .blocked)))
        records.apply(.report(.init(state: .blocked, id: "b")))
        #expect(records.presentation?.record.id == nil)
    }

    @Test(arguments: [TerminalProgramStatusEvent.prompt, .exit])
    func promptAndExitRemoveTransientRecordsButPreserveResults(_ event: TerminalProgramStatusEvent) {
        var records = TerminalProgramStatusRecords()
        for state in [TerminalProgramStatusReport.State.idle, .working, .blocked, .done, .error] {
            records.apply(.report(.init(state: state, id: state.rawValue)))
        }
        records.apply(event)
        #expect(Set(records.records.keys) == ["done", "error"])
        records.apply(.reset)
        #expect(records.records.isEmpty)
    }

    @Test
    func userInputAcknowledgesResultsWithoutInterruptingOtherTasks() {
        var records = TerminalProgramStatusRecords()
        records.apply(.report(.init(state: .done)))
        records.apply(.report(.init(state: .blocked, id: "question")))
        records.apply(.report(.init(state: .error, id: "failed")))
        records.acknowledgeResults()
        #expect(Set(records.records.keys) == ["question"])
    }

    @Test
    func finalReportsDeliveredAfterExitStillReplaceRecordsBeforeExitCleanup() {
        var records = TerminalProgramStatusRecords()
        records.apply(.exit)
        records.apply(.report(.init(state: .done, message: "Complete")))
        records.apply(.exit)
        #expect(records.presentation?.record.state == .done)
        records.apply(.report(.init(state: .working)))
        records.apply(.exit)
        #expect(records.presentation == nil)
    }

    @Test
    func capacityEvictsLeastRecentlyUpdatedRecordIncludingRoot() {
        var records = TerminalProgramStatusRecords()
        records.apply(.report(.init(state: .idle)))
        for index in 1..<256 {
            records.apply(.report(.init(state: .working, id: "task\(index)")))
        }
        records.apply(.report(.init(state: .blocked, id: "task1")))
        records.apply(.report(.init(state: .working, id: "new")))
        #expect(records.records.count == 256)
        #expect(records.records[""] == nil)
        #expect(records.records["task1"]?.state == .blocked)
        records.apply(.report(.init(state: .working, id: "next")))
        #expect(records.records["task2"] == nil)
        #expect(records.records.count == 256)
    }

    @Test
    func progressIsNeverEstimatedFromOtherTasks() {
        var records = TerminalProgramStatusRecords()
        records.apply(.report(.init(state: .working)))
        records.apply(.report(.init(state: .working, id: "a", progress: 0)))
        records.apply(.report(.init(state: .working, id: "b", progress: 100)))
        #expect(records.presentation?.record.progress == nil)
        records.apply(.report(.init(state: .blocked, id: "a", kind: .question, progress: 0)))
        #expect(records.presentation?.record.progress == 0)
    }
}
