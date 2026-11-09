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
        ] {
            #expect(throws: ToasttyCLIError.self, "\(arguments)") { _ = try command(arguments) }
        }
    }
}
