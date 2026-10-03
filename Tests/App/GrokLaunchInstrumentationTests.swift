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

    // Failures to prevent: missing native skills, shared-cache deletion breaking
    // a running agent, overriding caller workspace settings, and skill-copy
    // failures disabling the existing status hooks.
    func testSkillsCopiesSurviveSourceRemovalAndDispatchOnlyToTheManagedProcess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shipped = try fixture.skillTree("shipped", name: "toastty-fixture")
        let user = try fixture.skillTree("user", name: "user-fixture")
        let result = try fixture.prepare(["grok", "--resume=weekly work"], shipped: shipped, user: user)
        XCTAssertEqual(result.argv, ["grok", "--no-leader", "--resume=weekly work"])
        XCTAssertNil(result.environment["XAI_ROOT"])
        XCTAssertNil(result.environment["XAI_USER"])
        let overlay = try XCTUnwrap(result.environment[ToasttyLaunchContextEnvironment.grokSkillsOverlayKey])
        let permissions = try FileManager.default.attributesOfItem(atPath: overlay)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        let skills = URL(fileURLWithPath: overlay).appendingPathComponent("x/toastty/.grok/skills")
        try FileManager.default.removeItem(at: shipped)
        try FileManager.default.removeItem(at: user)
        XCTAssertTrue(FileManager.default.fileExists(atPath: skills.appendingPathComponent("shipped/toastty-fixture/SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skills.appendingPathComponent("user/user-fixture/SKILL.md").path))

        let observed = try fixture.dispatchEnvironment(result)
        XCTAssertEqual(observed["XAI_ROOT"], overlay)
        XCTAssertEqual(observed["XAI_USER"], "toastty")
        XCTAssertEqual(observed["TOASTTY_SKILLS_ROOT"], skills.appendingPathComponent("shipped").path)
        XCTAssertNil(observed[ToasttyLaunchContextEnvironment.grokSkillsOverlayKey])
    }

    func testDispatchPreservesCallerWorkspaceVariablesIncludingEmptyValues() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shipped = try fixture.skillTree("shipped", name: "toastty-fixture")
        let result = try fixture.prepare(["grok"], shipped: shipped)
        for inherited in [["XAI_ROOT": "/caller/root"], ["XAI_USER": ""], ["XAI_ROOT": "", "XAI_USER": "caller"]] {
            let observed = try fixture.dispatchEnvironment(result, inherited: inherited)
            XCTAssertEqual(observed["XAI_ROOT"], inherited["XAI_ROOT"])
            XCTAssertEqual(observed["XAI_USER"], inherited["XAI_USER"])
            XCTAssertNil(observed["TOASTTY_SKILLS_ROOT"])
            XCTAssertNil(observed[ToasttyLaunchContextEnvironment.grokSkillsOverlayKey])
        }
    }

    func testSkillCopyFailureKeepsHooksAndDoesNotPublishPartialOverlay() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shipped = try fixture.skillTree("shipped", name: "toastty-fixture")
        let result = try fixture.prepare(["grok"], shipped: shipped, user: fixture.root.appendingPathComponent("missing"))
        XCTAssertNotNil(result.artifacts)
        XCTAssertNil(result.environment[ToasttyLaunchContextEnvironment.grokSkillsOverlayKey])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("hooks/toastty-\(fixture.sessionID).json").path))
    }

    func testEnvironmentWrapperPreservesCallerWorkspaceInsteadOfAddingSkills() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shipped = try fixture.skillTree("shipped", name: "toastty-fixture")
        let result = try fixture.prepare(["env", "XAI_ROOT=/caller", "grok"], shipped: shipped)
        XCTAssertNil(result.environment[ToasttyLaunchContextEnvironment.grokSkillsOverlayKey])
        XCTAssertNotNil(result.artifacts)
        XCTAssertEqual(result.argv, ["env", "XAI_ROOT=/caller", "grok", "--no-leader"])
    }

    func testUserSkillsOnlyAndCleanupPreserveTheSourceSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let user = try fixture.skillTree("user", name: "user-fixture")
        let result = try fixture.prepare(["grok"], user: user)
        let observed = try fixture.dispatchEnvironment(result)
        XCTAssertNotNil(observed["XAI_ROOT"])
        XCTAssertNil(observed["TOASTTY_SKILLS_ROOT"])
        fixture.store.removeAbandoned(try XCTUnwrap(result.artifacts?.directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.appendingPathComponent("user-fixture/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(observed["XAI_ROOT"])))
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
        func prepare(_ arguments: [String], shipped: URL? = nil, user: URL? = nil) throws -> PreparedAgentLaunchCommand {
            try AgentLaunchInstrumentation.prepare(
                agent: .grok, argv: arguments, cliExecutablePath: "/tmp/toastty helper", sessionID: sessionID,
                workingDirectory: root.path, fileManager: .default, artifactStore: store,
                launchEnvironment: ["GROK_HOME": home.path],
                stagedSkillsIntegration: shipped.map {
                    ClaudeSkillsLaunchConfiguration(pluginRootPath: $0.deletingLastPathComponent().path, skillsRootPath: $0.path, version: "test", contentDigest: "test")
                },
                deliveredUserSkillsRootPath: user?.path
            )
        }
        func skillTree(_ directory: String, name: String) throws -> URL {
            let tree = root.appendingPathComponent(directory)
            let package = tree.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("---\nname: \(name)\ndescription: Test skill\n---\nFixture body\n".utf8)
                .write(to: package.appendingPathComponent("SKILL.md"))
            return tree
        }
        func dispatchEnvironment(_ result: PreparedAgentLaunchCommand, inherited: [String: String] = [:]) throws -> [String: String] {
            let keys = ["XAI_ROOT", "XAI_USER", "TOASTTY_SKILLS_ROOT", ToasttyLaunchContextEnvironment.grokSkillsOverlayKey]
            let script = "import json,os; print(json.dumps({k:os.environ[k] for k in \(keys) if k in os.environ}))"
            let argv = GrokLaunchInstrumentation.argvForDispatch(["/usr/bin/python3", "-c", script], environment: result.environment)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            process.environment = inherited.merging(result.environment) { _, new in new }
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: String])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
