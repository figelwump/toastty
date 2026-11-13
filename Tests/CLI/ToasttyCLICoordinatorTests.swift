import CoreState
import Foundation
import Testing
@testable import ToasttyCLIKit

struct ToasttyCLICoordinatorTests {
    private func command(_ arguments: [String], environment: [String: String] = [:]) throws -> CLICommand {
        try ToasttyCLI.parse(arguments: ["coordinator"] + arguments, environment: environment).command
    }

    @Test
    func eachSubcommandMapsToItsActionOrQuery() throws {
        let windowID = UUID().uuidString
        #expect(try command(["open"]) == .appControlRun(kind: .action, id: "coordinator.open", args: [:]))
        #expect(try command(["open", "--window", windowID, "--no-select"])
            == .appControlRun(kind: .action, id: "coordinator.open", args: ["windowID": .string(windowID), "select": .bool(false)]))
        #expect(try command(["restart"]) == .appControlRun(kind: .action, id: "coordinator.restart", args: [:]))
        #expect(try command(["restart", "--window", windowID])
            == .appControlRun(kind: .action, id: "coordinator.restart", args: ["windowID": .string(windowID)]))
        #expect(try command(["status"]) == .appControlRun(kind: .query, id: "coordinator.get", args: [:]))
    }

    @Test
    func sendTakesTheMessageAsAnArgumentOrAFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-cli-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "Two tasks changed.\nLook at the first.".write(
            to: directory.appendingPathComponent("wake.md"), atomically: true, encoding: .utf8
        )

        #expect(try command(["send", "status?"])
            == .appControlRun(kind: .action, id: "coordinator.send", args: ["text": .string("status?")]))
        #expect(try command(["send", "--text", "-- starts with dashes"])
            == .appControlRun(kind: .action, id: "coordinator.send", args: ["text": .string("-- starts with dashes")]))
        #expect(try command(["send", "--text-file", "wake.md"], environment: ["PWD": directory.path])
            == .appControlRun(kind: .action, id: "coordinator.send", args: ["text": .string("Two tasks changed.\nLook at the first.")]))
    }

    @Test
    func wakeSetsTheNextCheckByDurationByTimeOrClearsIt() throws {
        func wake(_ arguments: String...) throws -> CLICommand { try command(["wake"] + arguments) }
        for (duration, seconds) in [("90s", 90), ("20m", 1200), ("2h", 7200), ("1h30m", 5400), ("1d", 86400), ("2H", 7200)] {
            #expect(try wake("--in", duration)
                == .appControlRun(kind: .action, id: "coordinator.wake", args: ["inSeconds": .int(seconds)]), "\(duration)")
        }
        #expect(try wake("--at", "2026-11-09T18:30:00Z")
            == .appControlRun(kind: .action, id: "coordinator.wake", args: ["at": .string("2026-11-09T18:30:00Z")]))
        #expect(try wake("--clear") == .appControlRun(kind: .action, id: "coordinator.wake", args: ["clear": .bool(true)]))
        // The same call marks the wake turn quiet.
        #expect(try wake("--clear", "--quiet")
            == .appControlRun(kind: .action, id: "coordinator.wake", args: ["clear": .bool(true), "quiet": .bool(true)]))
        #expect(try wake("--quiet", "--in", "16m")
            == .appControlRun(kind: .action, id: "coordinator.wake", args: ["inSeconds": .int(960), "quiet": .bool(true)]))
    }

    @Test
    func watchNamesATaskOrAProjectAndRemoveEndsIt() throws {
        let taskID = UUID().uuidString
        let workspaceID = UUID().uuidString
        #expect(try command(["watch", "--task", taskID])
            == .appControlRun(kind: .action, id: "coordinator.watch", args: ["taskID": .string(taskID)]))
        #expect(try command(["watch", "--workspace", workspaceID])
            == .appControlRun(kind: .action, id: "coordinator.watch", args: ["workspaceID": .string(workspaceID)]))
        #expect(try command(["watch", "--task", taskID, "--remove"])
            == .appControlRun(kind: .action, id: "coordinator.watch", args: ["taskID": .string(taskID), "remove": .bool(true)]))
    }

    @Test
    func rejectsWrongOrAmbiguousArguments() {
        for arguments in [
            [],
            ["start"],
            ["open", "extra"],
            ["open", "--window", "not-an-id"],
            ["restart", "now"],
            ["status", "extra"],
            ["send"],
            ["send", "one", "two"],
            ["send", "one", "--text", "two"],
            ["send", "--text-file", "/nonexistent/toastty-coordinator-wake.md"],
            ["wake"],
            ["wake", "--in", "20"],
            ["wake", "--in", "soon"],
            ["wake", "--in", "m"],
            ["wake", "--in", "-5m"],
            ["wake", "--in", "20m", "--clear"],
            ["wake", "--at", "2026-11-09T18:30:00Z", "--in", "5m"],
            ["wake", "now", "--clear"],
            ["send", "hello", "--clear"],
            ["open", "--in", "5m"],
            ["wake", "--quiet"],
            ["send", "hello", "--quiet"],
            ["watch"],
            ["watch", "--task", "not-an-id"],
            ["watch", "--workspace", "not-an-id"],
            ["watch", "--task", UUID().uuidString, "--workspace", UUID().uuidString],
            ["watch", UUID().uuidString],
            ["watch", "--remove"],
            ["wake", "--clear", "--remove"],
            ["status", "--task", UUID().uuidString],
        ] {
            #expect(throws: ToasttyCLIError.self, "\(arguments)") { _ = try command(arguments) }
        }
    }
}
