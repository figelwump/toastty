import CoreState
import Darwin
import Foundation
import XCTest
@testable import ToasttyApp

final class GrokLaunchInstrumentationTests: XCTestCase {
    func testAbsolutePathDispatchRecordsTheGrokProcessBeforeExecution() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = fixture.root.appendingPathComponent("grok")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$$\"\numask\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let prepared = try fixture.prepare([executable.path])
        let arguments = GrokLaunchInstrumentation.argvForDispatch(prepared.argv, environment: prepared.environment)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "umask 027; exec \"$@\"", "test"] + arguments
        process.environment = prepared.environment
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        let actualPID = String(try XCTUnwrap(lines.first))
        let owner = try XCTUnwrap(prepared.artifacts?.directory.ownerRecordURL)
        XCTAssertEqual(try String(contentsOf: owner, encoding: .utf8), actualPID + "\n")
        XCTAssertEqual(actualPID, String(process.processIdentifier))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.last.flatMap { UInt16($0, radix: 8) }, 0o027)
    }

    func testGeneratedHookOnlyForwardsForMatchingSessionAndProducer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = fixture.root.appendingPathComponent("captured.json")
        let cli = fixture.root.appendingPathComponent("fake toastty")
        try Data("#!/bin/sh\ncat > \(AgentLaunchInstrumentation.shellQuote(capture.path))\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let result = try AgentLaunchInstrumentation.prepare(
            agent: .grok, argv: ["grok"], cliExecutablePath: cli.path,
            sessionID: fixture.sessionID, workingDirectory: fixture.root.path,
            fileManager: .default, artifactStore: fixture.store,
            launchEnvironment: ["GROK_HOME": fixture.home.path]
        )
        let directory = try XCTUnwrap(result.artifacts?.directory)
        let owner = try XCTUnwrap(directory.ownerRecordURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.directoryURL.appendingPathComponent("hooks.json"))) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: [[String: Any]]])
        let specs = try XCTUnwrap(hooks["UserPromptSubmit"]?.first?["hooks"] as? [[String: Any]])
        let command = try XCTUnwrap(specs.first?["command"] as? String)
        let payload = Data("{\"synthetic\":true}".utf8)
        for (session, producer, shouldForward) in [(fixture.sessionID, getpid(), true), ("other", getpid(), false), (fixture.sessionID, getpid() + 1, false)] {
            try? FileManager.default.removeItem(at: capture)
            try Data("\(producer)\n".utf8).write(to: owner)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ProcessInfo.processInfo.environment.merging(["TOASTTY_SESSION_ID": session]) { _, new in new }
            let input = Pipe(), output = Pipe(), error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            try process.run()
            input.fileHandleForWriting.write(payload)
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
            XCTAssertTrue(error.fileHandleForReading.readDataToEndOfFile().isEmpty)
            XCTAssertEqual(FileManager.default.fileExists(atPath: capture.path), shouldForward)
            if shouldForward { XCTAssertEqual(try Data(contentsOf: capture), payload) }
        }
    }

    func testAddsIsolatedHooksWithoutChangingResumeArgumentsOrUserHooks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let userHook = fixture.home.appendingPathComponent("hooks/user.json")
        try FileManager.default.createDirectory(at: userHook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user-owned".utf8).write(to: userHook)
        let arguments = ["grok", "--resume=weekly work", "--fork-session"]
        let result = try fixture.prepare(arguments)
        XCTAssertEqual(result.argv, ["grok", "--no-leader", "--resume=weekly work", "--fork-session"])
        let directory = try XCTUnwrap(result.artifacts?.directory)
        XCTAssertEqual(directory.lifetime, .agentProcess)
        XCTAssertEqual(result.environment[ToasttyLaunchContextEnvironment.managedAgentArtifactOwnerFileKey], directory.ownerRecordURL?.path)
        XCTAssertEqual(result.environment["GROK_HOME"], fixture.home.path)
        XCTAssertEqual(try String(contentsOf: userHook, encoding: .utf8), "user-owned")
        let link = fixture.home.appendingPathComponent("hooks/toastty-\(fixture.sessionID).json")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), directory.directoryURL.appendingPathComponent("hooks.json").path)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: link)) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["StopCancelled"])
        XCTAssertNil(hooks["PermissionRequest"])
    }

    func testDeclinesUnsafeOrUnrelatedInvocationsWithoutCreatingHooks() throws {
        for arguments in [["grok", "--leader"], ["grok", "login"], ["grok", "update"], ["grok", "--version"], ["wrapper", "grok"]] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let result = try fixture.prepare(arguments)
            XCTAssertEqual(result.argv, arguments)
            XCTAssertNil(result.artifacts)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("hooks").path))
        }
    }

    func testEnvironmentWrapperControlsHomeAndPreservesExplicitStandaloneFlag() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = fixture.root.appendingPathComponent("other home")
        let arguments = ["/usr/bin/env", "GROK_HOME=\(other.path)", "grok", "--no-leader", "--continue"]
        let result = try fixture.prepare(arguments)
        XCTAssertEqual(result.argv, arguments)
        XCTAssertEqual(result.environment["GROK_HOME"], other.path)
        XCTAssertNotNil(result.artifacts)
    }

    func testRelativeHomeAndSymlinkHooksDirectoryDeclineInstrumentation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let relative = try fixture.prepare(["env", "GROK_HOME=relative", "grok"])
        XCTAssertNil(relative.artifacts)
        let target = fixture.root.appendingPathComponent("user hooks")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.home.appendingPathComponent("hooks"), withDestinationURL: target)
        XCTAssertNil(try fixture.prepare(["grok"]).artifacts)
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let store: ManagedAgentLaunchArtifactStore
        let sessionID = UUID().uuidString
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("grok launch '\(UUID().uuidString)").standardizedFileURL
            home = root.appendingPathComponent("grok home")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = ManagedAgentLaunchArtifactStore(rootDirectoryURL: root.appendingPathComponent("launches"))
        }
        func prepare(_ arguments: [String]) throws -> PreparedAgentLaunchCommand {
            try AgentLaunchInstrumentation.prepare(agent: .grok, argv: arguments, cliExecutablePath: "/tmp/toastty helper", sessionID: sessionID, workingDirectory: root.path, fileManager: .default, artifactStore: store, launchEnvironment: ["GROK_HOME": home.path])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
