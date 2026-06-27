import Darwin
import Foundation
import XCTest

final class WorktreeCreateSkillScriptTests: XCTestCase {
    func testCreateWorktreeScriptUsesCurrentRepositoryWithoutBootstrap() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "worktree-create-generic")
        defer { try? fileManager.removeItem(at: rootURL) }

        let repoURL = try makeGitRepository(named: "emptyos", in: rootURL)
        let nestedURL = repoURL.appendingPathComponent("packages/app", isDirectory: true)
        try fileManager.createDirectory(at: nestedURL, withIntermediateDirectories: true)

        let result = try runScript(
            at: skillScriptURL(named: "create-worktree.sh"),
            environment: [:],
            arguments: [
                "--slug", "POP 1234",
                "--branch-prefix", "feat",
                "--parent-dir", rootURL.path,
                "--json",
            ],
            currentDirectoryURL: nestedURL
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")

        let payload = try jsonObject(from: result.stdout)
        XCTAssertEqual(payload["slug"] as? String, "pop-1234")
        XCTAssertEqual(payload["branch_name"] as? String, "feat/pop-1234")
        XCTAssertEqual(payload["worktree_name"] as? String, "emptyos-pop-1234")

        let expectedWorktreeURL = URL(fileURLWithPath: try realPath(rootURL), isDirectory: true)
            .appendingPathComponent("emptyos-pop-1234", isDirectory: true)
        let worktreePath = try XCTUnwrap(payload["worktree_path"] as? String)
        XCTAssertEqual(worktreePath, expectedWorktreeURL.path)
        XCTAssertEqual(payload["handoff_path"] as? String, "\(worktreePath)/WORKTREE_HANDOFF.md")
        XCTAssertTrue(fileManager.fileExists(atPath: worktreePath))
        XCTAssertFalse(result.stderr.contains("bootstrap-worktree.sh"))

        let branch = try runExecutable(
            "/usr/bin/git",
            arguments: ["rev-parse", "--abbrev-ref", "HEAD"],
            currentDirectoryURL: URL(fileURLWithPath: worktreePath, isDirectory: true)
        )
        XCTAssertEqual(branch.exitCode, 0)
        XCTAssertEqual(branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "feat/pop-1234")
    }

    func testCreateToasttyWorktreeCompatibilityWrapperUsesRequestedRepoRoot() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "worktree-create-wrapper")
        defer { try? fileManager.removeItem(at: rootURL) }

        let repoURL = try makeGitRepository(named: "emptyos", in: rootURL)

        let result = try runScript(
            at: skillScriptURL(named: "create-toastty-worktree.sh"),
            environment: [:],
            arguments: [
                "--repo-root", repoURL.path,
                "--slug", "Review Flow",
                "--branch-prefix", "debug",
                "--parent-dir", rootURL.path,
                "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("create-toastty-worktree.sh is deprecated"))

        let payload = try jsonObject(from: result.stdout)
        XCTAssertEqual(payload["branch_name"] as? String, "debug/review-flow")
        XCTAssertEqual(payload["worktree_name"] as? String, "emptyos-review-flow")
        let expectedWorktreeURL = URL(fileURLWithPath: try realPath(rootURL), isDirectory: true)
            .appendingPathComponent("emptyos-review-flow", isDirectory: true)
        XCTAssertEqual(payload["worktree_path"] as? String, expectedWorktreeURL.path)
    }

    func testCreateWorktreeScriptRejectsMissingSlug() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "worktree-create-missing-slug")
        defer { try? fileManager.removeItem(at: rootURL) }

        let repoURL = try makeGitRepository(named: "repo", in: rootURL)
        let result = try runScript(
            at: skillScriptURL(named: "create-worktree.sh"),
            environment: [:],
            arguments: ["--branch-prefix", "feat"],
            currentDirectoryURL: repoURL
        )

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("--slug is required"))
    }

    func testCreateWorktreeScriptRejectsNonGitDirectoryWithoutRepoRoot() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "worktree-create-no-git")
        defer { try? fileManager.removeItem(at: rootURL) }

        let result = try runScript(
            at: skillScriptURL(named: "create-worktree.sh"),
            environment: [:],
            arguments: ["--slug", "no-git"],
            currentDirectoryURL: rootURL
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("run inside a git worktree or pass --repo-root"))
    }

    func testCreateWorktreeScriptRejectsInvalidRepoRoot() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "worktree-create-invalid-root")
        defer { try? fileManager.removeItem(at: rootURL) }

        let result = try runScript(
            at: skillScriptURL(named: "create-worktree.sh"),
            environment: [:],
            arguments: [
                "--repo-root", rootURL.path,
                "--slug", "invalid-root",
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("--repo-root is not inside a git worktree"))
    }

    func testOpenSessionScriptRequiresPanelContextWhenWindowIDIsOmitted() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-worktree-create-script")
        defer { try? fileManager.removeItem(at: rootURL) }

        let worktreeURL = rootURL.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)

        let handoffURL = worktreeURL.appendingPathComponent("WORKTREE_HANDOFF.md", isDirectory: false)
        try Data("# Handoff\n".utf8).write(to: handoffURL, options: .atomic)

        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: [
                "TOASTTY_CLI_PATH": "/usr/bin/true",
                "TOASTTY_PANEL_ID": "",
            ],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", worktreeURL.path,
                "--handoff-file", handoffURL.path,
                "--startup-command", "printf 'noop\\n'",
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("TOASTTY_PANEL_ID is required when --window-id is omitted"))
    }

    func testOpenSessionScriptResolvesWindowIDFromTerminalStateAndUsesItForWorkspaceCreate() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-worktree-create-success")
        defer { try? fileManager.removeItem(at: rootURL) }

        let worktreeURL = rootURL.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)

        let handoffURL = worktreeURL.appendingPathComponent("WORKTREE_HANDOFF.md", isDirectory: false)
        try Data("# Handoff\n".utf8).write(to: handoffURL, options: .atomic)

        let invocationLogURL = rootURL.appendingPathComponent("cli-invocations.log", isDirectory: false)
        let fakeCLIURL = try makeFakeToasttyCLI(in: rootURL)

        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: [
                "FAKE_TOASTTY_LOG": invocationLogURL.path,
                "TOASTTY_CLI_PATH": fakeCLIURL.path,
                "TOASTTY_PANEL_ID": "33333333-3333-3333-3333-333333333333",
            ],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", worktreeURL.path,
                "--handoff-file", handoffURL.path,
                "--startup-command", "printf 'noop\\n'",
                "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.contains("\"window_id\": \"11111111-1111-1111-1111-111111111111\""))
        XCTAssertTrue(result.stdout.contains("\"workspace_id\": \"44444444-4444-4444-4444-444444444444\""))
        XCTAssertTrue(result.stdout.contains("\"panel_id\": \"55555555-5555-5555-5555-555555555555\""))
        XCTAssertTrue(result.stdout.contains("\"session_id\": null"))
        XCTAssertTrue(result.stdout.contains("\"scope_set\": false"))
        XCTAssertTrue(result.stdout.contains("\"parent_scope_status\": \"startup_command\""))
        XCTAssertTrue(result.stdout.contains("\"parent_scope_set\": false"))

        let invocations = try String(contentsOf: invocationLogURL, encoding: .utf8)
        let invocationLines = invocations
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        XCTAssertTrue(invocationLines.contains("--json query run terminal.state --panel 33333333-3333-3333-3333-333333333333"))
        XCTAssertTrue(invocationLines.contains("--json action run workspace.create --window 11111111-1111-1111-1111-111111111111 title=smoke activate=false"))
        XCTAssertFalse(invocationLines.contains(where: { $0.contains("workspace.snapshot") }))
        XCTAssertFalse(invocationLines.contains(where: { $0.contains("session scope") }))
        XCTAssertTrue(invocationLines.contains("action run panel.create.local-document --workspace 44444444-4444-4444-4444-444444444444 filePath=\(handoffURL.path)"))
        XCTAssertTrue(invocationLines.contains("--json query run terminal.state --workspace 44444444-4444-4444-4444-444444444444"))

        let documentIndex = try XCTUnwrap(invocationLines.firstIndex(of: "action run panel.create.local-document --workspace 44444444-4444-4444-4444-444444444444 filePath=\(handoffURL.path)"))
        let terminalStateIndex = try XCTUnwrap(invocationLines.lastIndex(of: "--json query run terminal.state --workspace 44444444-4444-4444-4444-444444444444"))
        XCTAssertLessThan(documentIndex, terminalStateIndex)
    }

    func testOpenSessionScriptDefaultStartupCommandLaunchesCodex() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-worktree-create-default-agent")
        defer { try? fileManager.removeItem(at: rootURL) }

        let worktreeURL = rootURL.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)

        let handoffURL = worktreeURL.appendingPathComponent("WORKTREE_HANDOFF.md", isDirectory: false)
        try Data("# Handoff\n".utf8).write(to: handoffURL, options: .atomic)

        let invocationLogURL = rootURL.appendingPathComponent("cli-invocations.log", isDirectory: false)
        let fakeCLIURL = try makeFakeToasttyCLI(in: rootURL)

        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: [
                "FAKE_TOASTTY_LOG": invocationLogURL.path,
                "TOASTTY_CLI_PATH": fakeCLIURL.path,
                "TOASTTY_PANEL_ID": "33333333-3333-3333-3333-333333333333",
                "TOASTTY_SESSION_ID": "77777777-7777-7777-7777-777777777777",
            ],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", worktreeURL.path,
                "--handoff-file", handoffURL.path,
                "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")

        let payload = try jsonObject(from: result.stdout)
        XCTAssertEqual(payload["session_id"] as? String, "66666666-6666-6666-6666-666666666666")
        XCTAssertEqual(payload["scope_set"] as? Bool, true)
        XCTAssertEqual(payload["parent_scope_status"] as? String, "set_current")
        XCTAssertEqual(payload["parent_scope_set"] as? Bool, true)

        let agentLaunchLine = try agentLaunchInvocationLine(invocationLogURL: invocationLogURL)
        XCTAssertTrue(agentLaunchLine.contains("profileID=codex"))
        XCTAssertTrue(agentLaunchLine.contains("cwd=\(worktreeURL.path)"))
        XCTAssertTrue(agentLaunchLine.contains("env.TOASTTY_DEV_WORKTREE_ROOT=\(worktreeURL.path)"))
        XCTAssertTrue(agentLaunchLine.contains("env.TOASTTY_DERIVED_PATH=\(worktreeURL.path)/artifacts/dev-runs/manual/Derived"))
        XCTAssertTrue(agentLaunchLine.contains("initialPrompt=Read WORKTREE_HANDOFF.md in the repo"))
        XCTAssertFalse(agentLaunchLine.contains("profileID=cdx"))
        XCTAssertFalse(try hasSendTextInvocation(invocationLogURL: invocationLogURL))

        let invocations = try String(contentsOf: invocationLogURL, encoding: .utf8)
        let invocationLines = invocations
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertTrue(invocationLines.contains("--json session scope show --session 77777777-7777-7777-7777-777777777777"))
        XCTAssertTrue(invocationLines.contains("--json session scope set-current --session 77777777-7777-7777-7777-777777777777"))
        XCTAssertTrue(invocationLines.contains("--json session scope set --session 66666666-6666-6666-6666-666666666666 --workspace 44444444-4444-4444-4444-444444444444"))

        let showIndex = try XCTUnwrap(invocationLines.firstIndex(of: "--json session scope show --session 77777777-7777-7777-7777-777777777777"))
        let parentScopeIndex = try XCTUnwrap(invocationLines.firstIndex(of: "--json session scope set-current --session 77777777-7777-7777-7777-777777777777"))
        let workspaceCreateIndex = try XCTUnwrap(invocationLines.firstIndex(of: "--json action run workspace.create --window 11111111-1111-1111-1111-111111111111 title=smoke activate=false"))
        let childScopeIndex = try XCTUnwrap(invocationLines.firstIndex(of: "--json session scope set --session 66666666-6666-6666-6666-666666666666 --workspace 44444444-4444-4444-4444-444444444444"))
        XCTAssertLessThan(showIndex, parentScopeIndex)
        XCTAssertLessThan(parentScopeIndex, workspaceCreateIndex)
        XCTAssertLessThan(workspaceCreateIndex, childScopeIndex)
    }

    func testOpenSessionScriptPreservesAlreadyScopedParentSession() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-worktree-create-scoped-parent")
        defer { try? fileManager.removeItem(at: rootURL) }

        let worktreeURL = rootURL.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)

        let handoffURL = worktreeURL.appendingPathComponent("WORKTREE_HANDOFF.md", isDirectory: false)
        try Data("# Handoff\n".utf8).write(to: handoffURL, options: .atomic)

        let invocationLogURL = rootURL.appendingPathComponent("cli-invocations.log", isDirectory: false)
        let fakeCLIURL = try makeFakeToasttyCLI(in: rootURL)

        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: [
                "FAKE_PARENT_ALREADY_SCOPED": "1",
                "FAKE_TOASTTY_LOG": invocationLogURL.path,
                "TOASTTY_CLI_PATH": fakeCLIURL.path,
                "TOASTTY_PANEL_ID": "33333333-3333-3333-3333-333333333333",
                "TOASTTY_SESSION_ID": "77777777-7777-7777-7777-777777777777",
            ],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", worktreeURL.path,
                "--handoff-file", handoffURL.path,
                "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")

        let payload = try jsonObject(from: result.stdout)
        XCTAssertEqual(payload["parent_scope_status"] as? String, "already_scoped")
        XCTAssertEqual(payload["parent_scope_set"] as? Bool, false)
        XCTAssertEqual(payload["scope_set"] as? Bool, true)

        let invocations = try String(contentsOf: invocationLogURL, encoding: .utf8)
        let invocationLines = invocations
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertTrue(invocationLines.contains("--json session scope show --session 77777777-7777-7777-7777-777777777777"))
        XCTAssertFalse(invocationLines.contains("--json session scope set-current --session 77777777-7777-7777-7777-777777777777"))
        XCTAssertTrue(invocationLines.contains("--json session scope set --session 66666666-6666-6666-6666-666666666666 --workspace 44444444-4444-4444-4444-444444444444"))
    }

    func testOpenSessionScriptCanSkipParentSessionScoping() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-worktree-create-no-parent-scope")
        defer { try? fileManager.removeItem(at: rootURL) }

        let worktreeURL = rootURL.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)

        let handoffURL = worktreeURL.appendingPathComponent("WORKTREE_HANDOFF.md", isDirectory: false)
        try Data("# Handoff\n".utf8).write(to: handoffURL, options: .atomic)

        let invocationLogURL = rootURL.appendingPathComponent("cli-invocations.log", isDirectory: false)
        let fakeCLIURL = try makeFakeToasttyCLI(in: rootURL)

        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: [
                "FAKE_TOASTTY_LOG": invocationLogURL.path,
                "TOASTTY_CLI_PATH": fakeCLIURL.path,
                "TOASTTY_PANEL_ID": "33333333-3333-3333-3333-333333333333",
            ],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", worktreeURL.path,
                "--handoff-file", handoffURL.path,
                "--no-scope-parent",
                "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")

        let payload = try jsonObject(from: result.stdout)
        XCTAssertEqual(payload["parent_scope_status"] as? String, "disabled")
        XCTAssertEqual(payload["parent_scope_set"] as? Bool, false)
        XCTAssertEqual(payload["scope_set"] as? Bool, true)

        let invocations = try String(contentsOf: invocationLogURL, encoding: .utf8)
        let invocationLines = invocations
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertFalse(invocationLines.contains(where: { $0.contains("session scope show") }))
        XCTAssertFalse(invocationLines.contains(where: { $0.contains("session scope set-current") }))
        XCTAssertTrue(invocationLines.contains("--json session scope set --session 66666666-6666-6666-6666-666666666666 --workspace 44444444-4444-4444-4444-444444444444"))
    }

    func testOpenSessionScriptRequiresSessionContextForDefaultParentScoping() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-worktree-create-parent-context")
        defer { try? fileManager.removeItem(at: rootURL) }

        let worktreeURL = rootURL.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)

        let handoffURL = worktreeURL.appendingPathComponent("WORKTREE_HANDOFF.md", isDirectory: false)
        try Data("# Handoff\n".utf8).write(to: handoffURL, options: .atomic)

        let invocationLogURL = rootURL.appendingPathComponent("cli-invocations.log", isDirectory: false)
        let fakeCLIURL = try makeFakeToasttyCLI(in: rootURL)

        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: [
                "FAKE_TOASTTY_LOG": invocationLogURL.path,
                "TOASTTY_CLI_PATH": fakeCLIURL.path,
                "TOASTTY_PANEL_ID": "33333333-3333-3333-3333-333333333333",
            ],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", worktreeURL.path,
                "--handoff-file", handoffURL.path,
                "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("TOASTTY_SESSION_ID is required to scope the parent session"))

        let invocations = try String(contentsOf: invocationLogURL, encoding: .utf8)
        XCTAssertFalse(invocations.contains("action run workspace.create"))
    }

    func testOpenSessionScriptRequiresPanelContextForDefaultParentScopingWithWindowOverride() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-worktree-create-parent-panel-context")
        defer { try? fileManager.removeItem(at: rootURL) }

        let worktreeURL = rootURL.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)

        let handoffURL = worktreeURL.appendingPathComponent("WORKTREE_HANDOFF.md", isDirectory: false)
        try Data("# Handoff\n".utf8).write(to: handoffURL, options: .atomic)

        let invocationLogURL = rootURL.appendingPathComponent("cli-invocations.log", isDirectory: false)
        let fakeCLIURL = try makeFakeToasttyCLI(in: rootURL)

        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: [
                "FAKE_TOASTTY_LOG": invocationLogURL.path,
                "TOASTTY_CLI_PATH": fakeCLIURL.path,
                "TOASTTY_PANEL_ID": "",
                "TOASTTY_SESSION_ID": "77777777-7777-7777-7777-777777777777",
            ],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", worktreeURL.path,
                "--handoff-file", handoffURL.path,
                "--window-id", "11111111-1111-1111-1111-111111111111",
                "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("TOASTTY_PANEL_ID is required to scope the parent session"))
        XCTAssertFalse(fileManager.fileExists(atPath: invocationLogURL.path))
    }

    func testOpenSessionScriptParsesParentScopeShowWhenCommandWritesStderr() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-worktree-create-parent-scope-stderr")
        defer { try? fileManager.removeItem(at: rootURL) }

        let worktreeURL = rootURL.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)

        let handoffURL = worktreeURL.appendingPathComponent("WORKTREE_HANDOFF.md", isDirectory: false)
        try Data("# Handoff\n".utf8).write(to: handoffURL, options: .atomic)

        let invocationLogURL = rootURL.appendingPathComponent("cli-invocations.log", isDirectory: false)
        let fakeCLIURL = try makeFakeToasttyCLI(in: rootURL)

        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: [
                "FAKE_PARENT_SCOPE_SHOW_STDERR": "1",
                "FAKE_TOASTTY_LOG": invocationLogURL.path,
                "TOASTTY_CLI_PATH": fakeCLIURL.path,
                "TOASTTY_PANEL_ID": "33333333-3333-3333-3333-333333333333",
                "TOASTTY_SESSION_ID": "77777777-7777-7777-7777-777777777777",
            ],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", worktreeURL.path,
                "--handoff-file", handoffURL.path,
                "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("scope show warning"))

        let payload = try jsonObject(from: result.stdout)
        XCTAssertEqual(payload["parent_scope_status"] as? String, "set_current")
        XCTAssertEqual(payload["parent_scope_set"] as? Bool, true)
        XCTAssertEqual(payload["scope_set"] as? Bool, true)
    }

    func testOpenSessionScriptRestoresParentScopeWhenWorkspaceCreateFails() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-worktree-create-parent-rollback")
        defer { try? fileManager.removeItem(at: rootURL) }

        let worktreeURL = rootURL.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)

        let handoffURL = worktreeURL.appendingPathComponent("WORKTREE_HANDOFF.md", isDirectory: false)
        try Data("# Handoff\n".utf8).write(to: handoffURL, options: .atomic)

        let invocationLogURL = rootURL.appendingPathComponent("cli-invocations.log", isDirectory: false)
        let fakeCLIURL = try makeFakeToasttyCLI(in: rootURL)

        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: [
                "FAKE_WORKSPACE_CREATE_FAILURE": "1",
                "FAKE_TOASTTY_LOG": invocationLogURL.path,
                "TOASTTY_CLI_PATH": fakeCLIURL.path,
                "TOASTTY_PANEL_ID": "33333333-3333-3333-3333-333333333333",
                "TOASTTY_SESSION_ID": "77777777-7777-7777-7777-777777777777",
            ],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", worktreeURL.path,
                "--handoff-file", handoffURL.path,
                "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("failed to create workspace"))

        let invocations = try String(contentsOf: invocationLogURL, encoding: .utf8)
        let invocationLines = invocations
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let parentScopeIndex = try XCTUnwrap(invocationLines.firstIndex(of: "--json session scope set-current --session 77777777-7777-7777-7777-777777777777"))
        let workspaceCreateIndex = try XCTUnwrap(invocationLines.firstIndex(of: "--json action run workspace.create --window 11111111-1111-1111-1111-111111111111 title=smoke activate=false"))
        let rollbackIndex = try XCTUnwrap(invocationLines.firstIndex(of: "--json session scope clear --session 77777777-7777-7777-7777-777777777777"))
        XCTAssertLessThan(parentScopeIndex, workspaceCreateIndex)
        XCTAssertLessThan(workspaceCreateIndex, rollbackIndex)
        XCTAssertFalse(invocationLines.contains(where: { $0.contains("action run agent.launch") }))
    }

    func testOpenSessionScriptFailsClearlyWhenAgentLaunchOmitsSessionID() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-worktree-create-missing-session")
        defer { try? fileManager.removeItem(at: rootURL) }

        let worktreeURL = rootURL.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)

        let handoffURL = worktreeURL.appendingPathComponent("WORKTREE_HANDOFF.md", isDirectory: false)
        try Data("# Handoff\n".utf8).write(to: handoffURL, options: .atomic)

        let invocationLogURL = rootURL.appendingPathComponent("cli-invocations.log", isDirectory: false)
        let fakeCLIURL = try makeFakeToasttyCLI(in: rootURL)

        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: [
                "FAKE_AGENT_LAUNCH_MISSING_SESSION": "1",
                "FAKE_TOASTTY_LOG": invocationLogURL.path,
                "TOASTTY_CLI_PATH": fakeCLIURL.path,
                "TOASTTY_PANEL_ID": "33333333-3333-3333-3333-333333333333",
                "TOASTTY_SESSION_ID": "77777777-7777-7777-7777-777777777777",
            ],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", worktreeURL.path,
                "--handoff-file", handoffURL.path,
                "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("agent.launch response did not include sessionID"))
        XCTAssertTrue(result.stderr.contains("without the intended workspace-only scope"))

        let invocations = try String(contentsOf: invocationLogURL, encoding: .utf8)
        let invocationLines = invocations
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertTrue(invocationLines.contains("--json session scope set-current --session 77777777-7777-7777-7777-777777777777"))
        XCTAssertFalse(invocationLines.contains("--json session scope set --session 66666666-6666-6666-6666-666666666666 --workspace 44444444-4444-4444-4444-444444444444"))
    }

    func testOpenSessionScriptFailsClearlyWhenScopeSetFails() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-worktree-create-scope-failure")
        defer { try? fileManager.removeItem(at: rootURL) }

        let worktreeURL = rootURL.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)

        let handoffURL = worktreeURL.appendingPathComponent("WORKTREE_HANDOFF.md", isDirectory: false)
        try Data("# Handoff\n".utf8).write(to: handoffURL, options: .atomic)

        let invocationLogURL = rootURL.appendingPathComponent("cli-invocations.log", isDirectory: false)
        let fakeCLIURL = try makeFakeToasttyCLI(in: rootURL)

        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: [
                "FAKE_SCOPE_FAILURE": "1",
                "FAKE_TOASTTY_LOG": invocationLogURL.path,
                "TOASTTY_CLI_PATH": fakeCLIURL.path,
                "TOASTTY_PANEL_ID": "33333333-3333-3333-3333-333333333333",
                "TOASTTY_SESSION_ID": "77777777-7777-7777-7777-777777777777",
            ],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", worktreeURL.path,
                "--handoff-file", handoffURL.path,
                "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("failed to scope session 66666666-6666-6666-6666-666666666666"))
        XCTAssertTrue(result.stderr.contains("without the intended workspace-only scope"))

        let invocations = try String(contentsOf: invocationLogURL, encoding: .utf8)
        let invocationLines = invocations
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertTrue(invocationLines.contains("--json session scope set --session 66666666-6666-6666-6666-666666666666 --workspace 44444444-4444-4444-4444-444444444444"))
    }

    func testOpenSessionScriptHonorsAgentCommandOverride() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-worktree-create-agent-override")
        defer { try? fileManager.removeItem(at: rootURL) }

        let worktreeURL = rootURL.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)

        let handoffURL = worktreeURL.appendingPathComponent("WORKTREE_HANDOFF.md", isDirectory: false)
        try Data("# Handoff\n".utf8).write(to: handoffURL, options: .atomic)

        let invocationLogURL = rootURL.appendingPathComponent("cli-invocations.log", isDirectory: false)
        let fakeCLIURL = try makeFakeToasttyCLI(in: rootURL)

        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: [
                "FAKE_TOASTTY_LOG": invocationLogURL.path,
                "TOASTTY_CLI_PATH": fakeCLIURL.path,
                "TOASTTY_PANEL_ID": "33333333-3333-3333-3333-333333333333",
                "TOASTTY_SESSION_ID": "77777777-7777-7777-7777-777777777777",
            ],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", worktreeURL.path,
                "--handoff-file", handoffURL.path,
                "--agent-command", "claude",
                "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")

        let agentLaunchLine = try agentLaunchInvocationLine(invocationLogURL: invocationLogURL)
        XCTAssertTrue(agentLaunchLine.contains("profileID=claude"))
        XCTAssertTrue(agentLaunchLine.contains("cwd=\(worktreeURL.path)"))
        XCTAssertTrue(agentLaunchLine.contains("env.TOASTTY_DEV_WORKTREE_ROOT=\(worktreeURL.path)"))
        XCTAssertTrue(agentLaunchLine.contains("env.TOASTTY_DERIVED_PATH=\(worktreeURL.path)/artifacts/dev-runs/manual/Derived"))
        XCTAssertTrue(agentLaunchLine.contains("initialPrompt=Read WORKTREE_HANDOFF.md in the repo"))
        XCTAssertFalse(agentLaunchLine.contains("profileID=codex"))
        XCTAssertFalse(try hasSendTextInvocation(invocationLogURL: invocationLogURL))
    }

    func testOpenSessionScriptPassesInitialCommandsToStructuredAgentLaunch() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-worktree-create-initial-commands")
        defer { try? fileManager.removeItem(at: rootURL) }

        let worktreeURL = rootURL.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)

        let handoffURL = worktreeURL.appendingPathComponent("WORKTREE_HANDOFF.md", isDirectory: false)
        try Data("# Handoff\n".utf8).write(to: handoffURL, options: .atomic)

        let invocationLogURL = rootURL.appendingPathComponent("cli-invocations.log", isDirectory: false)
        let fakeCLIURL = try makeFakeToasttyCLI(in: rootURL)

        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: [
                "FAKE_TOASTTY_LOG": invocationLogURL.path,
                "TOASTTY_CLI_PATH": fakeCLIURL.path,
                "TOASTTY_PANEL_ID": "33333333-3333-3333-3333-333333333333",
                "TOASTTY_SESSION_ID": "77777777-7777-7777-7777-777777777777",
            ],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", worktreeURL.path,
                "--handoff-file", handoffURL.path,
                "--initial-command", "direnv allow",
                "--initial-command", "printf ready",
                "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")

        let agentLaunchLine = try agentLaunchInvocationLine(invocationLogURL: invocationLogURL)
        XCTAssertTrue(agentLaunchLine.contains("profileID=codex"))
        XCTAssertTrue(agentLaunchLine.contains("cwd=\(worktreeURL.path)"))
        XCTAssertTrue(agentLaunchLine.contains("initialCommands=direnv allow"))
        XCTAssertTrue(agentLaunchLine.contains("initialCommands=printf ready"))
        XCTAssertTrue(agentLaunchLine.contains("initialPrompt=Read WORKTREE_HANDOFF.md in the repo"))
        XCTAssertFalse(try hasSendTextInvocation(invocationLogURL: invocationLogURL))
    }

    func testOpenSessionScriptRejectsAgentCommandCombinedWithStartupCommand() throws {
        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: ["TOASTTY_CLI_PATH": "/usr/bin/true"],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", "/tmp/toastty-worktree-create-missing",
                "--handoff-file", "/tmp/toastty-worktree-create-missing/WORKTREE_HANDOFF.md",
                "--agent-command", "claude",
                "--startup-command", "printf 'noop\\n'",
            ]
        )

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("--agent-command cannot be combined with --startup-command"))
    }

    func testOpenSessionScriptRejectsInitialCommandCombinedWithStartupCommand() throws {
        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: ["TOASTTY_CLI_PATH": "/usr/bin/true"],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", "/tmp/toastty-worktree-create-missing",
                "--handoff-file", "/tmp/toastty-worktree-create-missing/WORKTREE_HANDOFF.md",
                "--initial-command", "direnv allow",
                "--startup-command", "printf 'noop\\n'",
            ]
        )

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("--initial-command cannot be combined with --startup-command"))
    }

    func testOpenSessionScriptRejectsMultilineInitialCommand() throws {
        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: ["TOASTTY_CLI_PATH": "/usr/bin/true"],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", "/tmp/toastty-worktree-create-missing",
                "--handoff-file", "/tmp/toastty-worktree-create-missing/WORKTREE_HANDOFF.md",
                "--initial-command", "direnv allow\nprintf ready",
            ]
        )

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("--initial-command must be a single-line command"))
    }

    func testOpenSessionScriptRejectsAgentCommandWithWhitespace() throws {
        let result = try runScript(
            at: skillScriptURL(named: "open-toastty-worktree-session.sh"),
            environment: ["TOASTTY_CLI_PATH": "/usr/bin/true"],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", "/tmp/toastty-worktree-create-missing",
                "--handoff-file", "/tmp/toastty-worktree-create-missing/WORKTREE_HANDOFF.md",
                "--agent-command", "claude --resume",
            ]
        )

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("--agent-command must be a single executable name"))
    }

    private func sendTextInvocationLine(invocationLogURL: URL) throws -> String {
        let invocations = try String(contentsOf: invocationLogURL, encoding: .utf8)
        return try XCTUnwrap(
            invocations
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .first(where: { $0.contains("action run terminal.send-text") })
        )
    }

    private func hasSendTextInvocation(invocationLogURL: URL) throws -> Bool {
        let invocations = try String(contentsOf: invocationLogURL, encoding: .utf8)
        return invocations
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .contains(where: { $0.contains("action run terminal.send-text") })
    }

    private func agentLaunchInvocationLine(invocationLogURL: URL) throws -> String {
        let invocations = try String(contentsOf: invocationLogURL, encoding: .utf8)
        return try XCTUnwrap(
            invocations
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .first(where: { $0.contains("action run agent.launch") })
        )
    }

    private func makeFakeToasttyCLI(in rootURL: URL) throws -> URL {
        try makeExecutableScript(
            named: "fake-toastty-cli",
            contents: """
            #!/bin/sh
            set -eu
            printf '%s\\n' \"$*\" >> \"${FAKE_TOASTTY_LOG:?}\"
            if [ \"${1:-}\" = \"--json\" ]; then
              shift
            fi
            case \"$1 $2 $3\" in
              \"query run terminal.state\")
                if [ \"${4:-}\" = \"--panel\" ]; then
                  cat <<'EOF'
            {"result":{"windowID":"11111111-1111-1111-1111-111111111111","workspaceID":"22222222-2222-2222-2222-222222222222","panelID":"33333333-3333-3333-3333-333333333333","title":"~","cwd":"/tmp","shell":"zsh","profileID":null}}
            EOF
                else
                  cat <<'EOF'
            {"result":{"windowID":"11111111-1111-1111-1111-111111111111","workspaceID":"44444444-4444-4444-4444-444444444444","panelID":"55555555-5555-5555-5555-555555555555","title":"workspace terminal","cwd":"/tmp/worktree","shell":"zsh","profileID":null}}
            EOF
                fi
                ;;
              \"action run workspace.create\")
                if [ "${FAKE_WORKSPACE_CREATE_FAILURE:-0}" = "1" ]; then
                  cat <<'EOF'
            {"error":{"code":"workspace_failed","message":"workspace create failure"}}
            EOF
                  exit 1
                fi
                cat <<'EOF'
            {"result":{"windowID":"11111111-1111-1111-1111-111111111111","workspaceID":"44444444-4444-4444-4444-444444444444"}}
            EOF
                ;;
              \"action run agent.launch\")
                if [ "${FAKE_AGENT_LAUNCH_MISSING_SESSION:-0}" = "1" ]; then
                  cat <<'EOF'
            {"result":{"profileID":"codex","agent":"codex","displayName":"Codex","windowID":"11111111-1111-1111-1111-111111111111","workspaceID":"44444444-4444-4444-4444-444444444444","panelID":"55555555-5555-5555-5555-555555555555","command":"cd /tmp/worktree && codex prompt","cwd":"/tmp/worktree"}}
            EOF
                  exit 0
                fi
                cat <<'EOF'
            {"result":{"profileID":"codex","agent":"codex","displayName":"Codex","sessionID":"66666666-6666-6666-6666-666666666666","windowID":"11111111-1111-1111-1111-111111111111","workspaceID":"44444444-4444-4444-4444-444444444444","panelID":"55555555-5555-5555-5555-555555555555","command":"cd /tmp/worktree && codex prompt","cwd":"/tmp/worktree"}}
            EOF
                ;;
              \"session scope show\")
                if [ "${FAKE_PARENT_SCOPE_SHOW_STDERR:-0}" = "1" ]; then
                  printf 'scope show warning\\n' >&2
                fi
                if [ "${FAKE_PARENT_ALREADY_SCOPED:-0}" = "1" ]; then
                  cat <<'EOF'
            {"result":{"sessionID":"77777777-7777-7777-7777-777777777777","isScoped":true,"workspaceIDs":["88888888-8888-8888-8888-888888888888"],"effectiveWorkspaceIDs":["22222222-2222-2222-2222-222222222222","88888888-8888-8888-8888-888888888888"]}}
            EOF
                  exit 0
                fi
                cat <<'EOF'
            {"result":{"sessionID":"77777777-7777-7777-7777-777777777777","isScoped":false,"workspaceIDs":[],"effectiveWorkspaceIDs":null}}
            EOF
                ;;
              \"session scope set-current\")
                cat <<'EOF'
            {"result":{"sessionID":"77777777-7777-7777-7777-777777777777","isScoped":true,"workspaceIDs":[],"effectiveWorkspaceIDs":["22222222-2222-2222-2222-222222222222"]}}
            EOF
                ;;
              \"session scope clear\")
                cat <<'EOF'
            {"result":{"sessionID":"77777777-7777-7777-7777-777777777777","isScoped":false,"workspaceIDs":[],"effectiveWorkspaceIDs":null}}
            EOF
                ;;
              \"session scope set\")
                if [ "${FAKE_SCOPE_FAILURE:-0}" = "1" ]; then
                  cat <<'EOF'
            {"error":{"code":"scope_failed","message":"scope failure"}}
            EOF
                  exit 1
                fi
                cat <<'EOF'
            {"result":{"sessionID":"66666666-6666-6666-6666-666666666666","isScoped":true,"workspaceIDs":["44444444-4444-4444-4444-444444444444"],"effectiveWorkspaceIDs":["44444444-4444-4444-4444-444444444444"]}}
            EOF
                ;;
              \"action run terminal.send-text\")
                cat <<'EOF'
            {"result":{"workspaceID":"44444444-4444-4444-4444-444444444444","panelID":"55555555-5555-5555-5555-555555555555","submitted":true,"available":true}}
            EOF
                ;;
              *)
                printf 'ran %s\\n' \"$2\"
                ;;
            esac
            """,
            in: rootURL
        )
    }

    private func skillScriptURL(named scriptName: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".agents/skills/worktree-create/scripts/\(scriptName)", isDirectory: false)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func makeExecutableScript(
        named name: String,
        contents: String,
        in directoryURL: URL
    ) throws -> URL {
        let scriptURL = directoryURL.appendingPathComponent(name, isDirectory: false)
        try Data(contents.appending("\n").utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    private func makeGitRepository(named name: String, in rootURL: URL) throws -> URL {
        let repoURL = rootURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try Data("# \(name)\n".utf8).write(
            to: repoURL.appendingPathComponent("README.md", isDirectory: false),
            options: .atomic
        )
        try assertSuccessful(runExecutable("/usr/bin/git", arguments: ["init"], currentDirectoryURL: repoURL))
        try assertSuccessful(runExecutable("/usr/bin/git", arguments: ["add", "README.md"], currentDirectoryURL: repoURL))
        try assertSuccessful(
            runExecutable(
                "/usr/bin/git",
                arguments: [
                    "-c", "user.name=Toastty Tests",
                    "-c", "user.email=toastty-tests@example.invalid",
                    "commit",
                    "-m", "initial",
                ],
                currentDirectoryURL: repoURL
            )
        )
        return repoURL
    }

    private func realPath(_ url: URL) throws -> String {
        try url.path.withCString { pathPointer in
            guard let resolvedPointer = Darwin.realpath(pathPointer, nil) else {
                throw NSError(
                    domain: "WorktreeCreateSkillScriptTests",
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "Failed to resolve real path for \(url.path)"]
                )
            }
            defer { free(resolvedPointer) }
            return String(cString: resolvedPointer)
        }
    }

    private func assertSuccessful(
        _ result: (exitCode: Int32, stdout: String, stderr: String),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(result.exitCode, 0, "stdout:\n\(result.stdout)\nstderr:\n\(result.stderr)", file: file, line: line)
    }

    private func jsonObject(from stdout: String) throws -> [String: Any] {
        let data = try XCTUnwrap(stdout.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func runScript(
        at scriptURL: URL,
        environment: [String: String],
        arguments: [String],
        currentDirectoryURL: URL? = nil
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try runExecutable(
            scriptURL.path,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: environment
        )
    }

    private func runExecutable(
        _ executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String] = [:]
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.currentDirectoryURL = currentDirectoryURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            throw NSError(
                domain: "WorktreeCreateSkillScriptTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Process timed out: \(executablePath)"]
            )
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}
