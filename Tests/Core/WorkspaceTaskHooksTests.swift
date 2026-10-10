import CoreState
import Foundation
import Testing

struct WorkspaceTaskHooksTests {
    private struct Fixture {
        var state: AppState
        let windowID: UUID
        let workspaceIDs: [UUID]

        init(workspaceCount: Int = 3) {
            let windowID = UUID()
            let workspaces = (0..<workspaceCount).map { index in
                WorkspaceState.bootstrap(title: "Workspace \(index + 1)")
            }
            state = AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                        workspaceIDs: workspaces.map(\.id),
                        selectedWorkspaceID: workspaces[0].id
                    ),
                ],
                workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
                selectedWindowID: windowID,
                configuredTerminalFontPoints: nil
            )
            self.windowID = windowID
            workspaceIDs = workspaces.map(\.id)
        }

        mutating func nest(_ index: Int, under parentIndex: Int) -> Bool {
            AppReducer.reduce(
                action: .setWorkspaceParent(
                    workspaceID: workspaceIDs[index],
                    parentWorkspaceID: workspaceIDs[parentIndex],
                    spawningSessionID: "spawner"
                ),
                state: &state
            )
        }
    }

    private static let hooks = WorkspaceTaskHooks(
        finishSkill: "worktree-done",
        cleanup: WorkspaceTaskHooks.ScriptHook(
            skill: "worktree-cleanup",
            script: "scripts/worktree-status.py",
            arguments: ["--cleanup-workspace"]
        )
    )

    @Test
    func validationKeepsHooksInsideInstalledSkills() {
        #expect(WorkspaceTaskHooks.validatedSkillName(" worktree-done ") == "worktree-done")
        #expect(WorkspaceTaskHooks.validatedSkillName("") == nil)
        #expect(WorkspaceTaskHooks.validatedSkillName("../other") == nil)
        #expect(WorkspaceTaskHooks.validatedSkillName(".hidden") == nil)
        #expect(WorkspaceTaskHooks.validatedSkillName("has space") == nil)
        #expect(WorkspaceTaskHooks.validatedSkillName(String(repeating: "a", count: 65)) == nil)

        #expect(WorkspaceTaskHooks.validatedScriptPath("scripts/cleanup.py") == "scripts/cleanup.py")
        #expect(WorkspaceTaskHooks.validatedScriptPath("/etc/passwd") == nil)
        #expect(WorkspaceTaskHooks.validatedScriptPath("../../bin/rm") == nil)
        #expect(WorkspaceTaskHooks.validatedScriptPath("scripts//x") == nil)
        #expect(WorkspaceTaskHooks.validatedScriptPath("scripts/./x") == nil)

        #expect(WorkspaceTaskHooks.validatedArguments(["--cleanup-workspace"]) == ["--cleanup-workspace"])
        #expect(WorkspaceTaskHooks.validatedArguments([""]) == nil)
        #expect(WorkspaceTaskHooks.validatedArguments(["a\nb"]) == nil)
        #expect(WorkspaceTaskHooks.validatedArguments(Array(repeating: "x", count: 17)) == nil)

        // A hand-edited layout file keeps what is valid and drops the rest.
        let sanitized = WorkspaceTaskHooks(
            finishSkill: "../escape",
            cleanup: WorkspaceTaskHooks.ScriptHook(skill: "ok", script: "run.sh")
        ).sanitized
        #expect(sanitized.finishSkill == nil)
        #expect(sanitized.cleanup?.skill == "ok")

        let closeOnly = WorkspaceTaskHooks(close: WorkspaceTaskHooks.ScriptHook(skill: "worktree-cleanup", script: "scripts/x.py"))
        #expect(closeOnly.isEmpty == false)
        #expect(closeOnly.script(.close)?.script == "scripts/x.py")
        #expect(closeOnly.script(.cleanup) == nil)
        #expect(WorkspaceTaskHooks(close: WorkspaceTaskHooks.ScriptHook(skill: "x", script: "/abs")).sanitized.isEmpty)
    }

    @Test
    func hooksBelongToSubspacesAndSurviveALayoutRoundTrip() throws {
        var fixture = Fixture()
        let ids = fixture.workspaceIDs
        // A top-level workspace has no buttons to show them on.
        #expect(AppReducer.reduce(action: .setWorkspaceTaskHooks(workspaceID: ids[0], hooks: Self.hooks), state: &fixture.state) == false)
        #expect(fixture.state.workspacesByID[ids[0]]?.taskHooks.isEmpty == true)

        let didNest = fixture.nest(1, under: 0)
        #expect(didNest)
        #expect(AppReducer.reduce(action: .setWorkspaceTaskHooks(workspaceID: ids[1], hooks: Self.hooks), state: &fixture.state))
        // Setting the same hooks again changes nothing.
        #expect(AppReducer.reduce(action: .setWorkspaceTaskHooks(workspaceID: ids[1], hooks: Self.hooks), state: &fixture.state) == false)
        #expect(fixture.state.workspacesByID[ids[1]]?.taskHooks == Self.hooks)

        let encoded = try JSONEncoder().encode(WorkspaceLayoutSnapshot(state: fixture.state))
        let restored = try JSONDecoder().decode(WorkspaceLayoutSnapshot.self, from: encoded).makeAppState()
        #expect(restored.workspacesByID[ids[1]]?.taskHooks == Self.hooks)
        #expect(restored.workspacesByID[ids[0]]?.taskHooks.isEmpty == true)

        // Empty hooks clear them, on a subspace or anywhere.
        #expect(AppReducer.reduce(action: .setWorkspaceTaskHooks(workspaceID: ids[1], hooks: WorkspaceTaskHooks()), state: &fixture.state))
        #expect(fixture.state.workspacesByID[ids[1]]?.taskHooks.isEmpty == true)
    }

    @Test
    func hooksDropWhenASubspaceMovesToTopLevelOrItsParentCloses() {
        var fixture = Fixture()
        let ids = fixture.workspaceIDs
        let didNestFirst = fixture.nest(1, under: 0)
        let didNestSecond = fixture.nest(2, under: 0)
        #expect(didNestFirst && didNestSecond)
        #expect(AppReducer.reduce(action: .setWorkspaceTaskHooks(workspaceID: ids[1], hooks: Self.hooks), state: &fixture.state))
        #expect(AppReducer.reduce(action: .setWorkspaceTaskHooks(workspaceID: ids[2], hooks: Self.hooks), state: &fixture.state))

        #expect(AppReducer.reduce(
            action: .setWorkspaceParent(workspaceID: ids[1], parentWorkspaceID: nil, spawningSessionID: nil),
            state: &fixture.state
        ))
        #expect(fixture.state.workspacesByID[ids[1]]?.taskHooks.isEmpty == true)

        #expect(AppReducer.reduce(action: .closeWorkspace(workspaceID: ids[0]), state: &fixture.state))
        #expect(fixture.state.workspacesByID[ids[2]]?.taskHooks.isEmpty == true)
    }

    /// open → review → done, and back: review and done belong to subspaces,
    /// open clears both marks, and the marks survive a layout round trip.
    @Test
    func taskStageMovesThroughReviewAndDoneAndBack() throws {
        var fixture = Fixture()
        let ids = fixture.workspaceIDs
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)

        // A top-level workspace is always open.
        #expect(AppReducer.reduce(action: .setWorkspaceTaskStage(workspaceID: ids[0], stage: .review, at: t0), state: &fixture.state) == false)
        #expect(AppReducer.reduce(action: .setWorkspaceTaskStage(workspaceID: ids[0], stage: .done, at: t0), state: &fixture.state) == false)
        #expect(fixture.state.workspacesByID[ids[0]]?.taskStage == .open)

        let didNest = fixture.nest(1, under: 0)
        #expect(didNest)
        #expect(fixture.state.workspacesByID[ids[1]]?.taskStage == .open)
        #expect(AppReducer.reduce(action: .setWorkspaceTaskStage(workspaceID: ids[1], stage: .open, at: t0), state: &fixture.state) == false, "already open")

        #expect(AppReducer.reduce(action: .setWorkspaceTaskStage(workspaceID: ids[1], stage: .review, at: t0), state: &fixture.state))
        #expect(fixture.state.workspacesByID[ids[1]]?.taskStage == .review)
        #expect(fixture.state.workspacesByID[ids[1]]?.reviewReadyAt == t0)
        #expect(AppReducer.reduce(action: .setWorkspaceTaskStage(workspaceID: ids[1], stage: .review, at: t1), state: &fixture.state) == false, "review keeps its first time")

        #expect(AppReducer.reduce(action: .setWorkspaceTaskStage(workspaceID: ids[1], stage: .done, at: t1), state: &fixture.state))
        #expect(fixture.state.workspacesByID[ids[1]]?.taskStage == .done)
        #expect(fixture.state.workspacesByID[ids[1]]?.doneAt == t1)

        let encoded = try JSONEncoder().encode(WorkspaceLayoutSnapshot(state: fixture.state))
        let restored = try JSONDecoder().decode(WorkspaceLayoutSnapshot.self, from: encoded).makeAppState()
        #expect(restored.workspacesByID[ids[1]]?.taskStage == .done)
        #expect(restored.workspacesByID[ids[1]]?.reviewReadyAt == t0)

        // Back to review drops the done mark; the set-done form still works
        // on top of a review mark.
        #expect(AppReducer.reduce(action: .setWorkspaceTaskStage(workspaceID: ids[1], stage: .review, at: t1), state: &fixture.state))
        #expect(fixture.state.workspacesByID[ids[1]]?.taskStage == .review)
        #expect(fixture.state.workspacesByID[ids[1]]?.doneAt == nil)
        #expect(AppReducer.reduce(action: .setWorkspaceDone(workspaceID: ids[1], doneAt: t1), state: &fixture.state))
        #expect(fixture.state.workspacesByID[ids[1]]?.taskStage == .done)

        // Reopen clears both marks at once, through either form.
        #expect(AppReducer.reduce(action: .setWorkspaceDone(workspaceID: ids[1], doneAt: nil), state: &fixture.state))
        #expect(fixture.state.workspacesByID[ids[1]]?.taskStage == .open)
        #expect(fixture.state.workspacesByID[ids[1]]?.reviewReadyAt == nil)
        #expect(fixture.state.workspacesByID[ids[1]]?.doneAt == nil)
        #expect(AppReducer.reduce(action: .setWorkspaceTaskStage(workspaceID: ids[1], stage: .review, at: t1), state: &fixture.state))
        #expect(AppReducer.reduce(action: .setWorkspaceDone(workspaceID: ids[1], doneAt: nil), state: &fixture.state), "clear-done reopens a task in review")
        #expect(fixture.state.workspacesByID[ids[1]]?.taskStage == .open)
        #expect(AppReducer.reduce(action: .setWorkspaceTaskStage(workspaceID: ids[1], stage: .open, at: t1), state: &fixture.state) == false)


        // Leaving the parent drops the stage with the hooks.
        #expect(AppReducer.reduce(action: .setWorkspaceTaskStage(workspaceID: ids[1], stage: .review, at: t1), state: &fixture.state))
        #expect(AppReducer.reduce(
            action: .setWorkspaceParent(workspaceID: ids[1], parentWorkspaceID: nil, spawningSessionID: nil),
            state: &fixture.state
        ))
        #expect(fixture.state.workspacesByID[ids[1]]?.taskStage == .open)

        // Closing the parent drops a review mark with the hooks.
        let didNestOther = fixture.nest(2, under: 0)
        #expect(didNestOther)
        #expect(AppReducer.reduce(action: .setWorkspaceTaskStage(workspaceID: ids[2], stage: .review, at: t1), state: &fixture.state))
        #expect(AppReducer.reduce(action: .closeWorkspace(workspaceID: ids[0]), state: &fixture.state))
        #expect(fixture.state.workspacesByID[ids[2]]?.taskStage == .open)
    }

    @Test
    func workspaceStateDecodingDropsMalformedHooksAndKeepsTheWorkspace() throws {
        var fixture = Fixture(workspaceCount: 2)
        let didNest = fixture.nest(1, under: 0)
        #expect(didNest)
        #expect(AppReducer.reduce(action: .setWorkspaceTaskHooks(workspaceID: fixture.workspaceIDs[1], hooks: Self.hooks), state: &fixture.state))
        let subspace = try #require(fixture.state.workspacesByID[fixture.workspaceIDs[1]])

        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(subspace))
        #expect(decoded.taskHooks == Self.hooks)

        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(subspace)) as? [String: Any])
        object["taskHooks"] = ["finishSkill": "fine", "cleanup": ["skill": "x", "script": "../escape", "arguments": []]]
        let malformed = try JSONDecoder().decode(WorkspaceState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(malformed.id == subspace.id)
        #expect(malformed.taskHooks.finishSkill == "fine")
        #expect(malformed.taskHooks.cleanup == nil)

        object["taskHooks"] = "not an object"
        let broken = try JSONDecoder().decode(WorkspaceState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(broken.taskHooks.isEmpty)
    }
}
