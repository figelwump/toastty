import CoreState
import Darwin
import Foundation
import RemoteProtocol

extension TaskCoordinator {
    static let releaseCheckInterval: Duration = .seconds(15 * 60)

    /// Save the release agent's explicit choice before applying its annotation.
    @discardableResult
    func setReleasePreparationPullRequest(_ link: WorkspacePullRequestLink?, for record: TaskRecord) throws -> Bool {
        guard record.release?.preparationPullRequestURL != link?.url || record.pullRequestURL != link?.url else {
            return false
        }
        try saveMergeState(taskID: record.id) {
            $0.release?.preparationPullRequestURL = link?.url
            $0.pullRequestURL = link?.url
            Self.resetReleaseMerge(&$0)
        }
        return true
    }

    /// A saved cleanup from a release preparation merge used the ordinary
    /// task path. End that request before it can act on the release checkout.
    /// Keep the link so the release agent can confirm it again.
    func reconcileReleaseMerges() {
        for record in records.records where record.release != nil {
            guard let workspaceID = record.taskSpaceWorkspaceID,
                  let workspace = store.state.workspacesByID[workspaceID],
                  workspace.taskID == record.id else { continue }
            let droppedOldRequest = merges?.discardReleaseMergeCleanup(workspaceID: workspaceID) == true
            if let doneAt = record.doneAt {
                // The merge coordinator can drop a stale wait before the
                // task coordinator starts. Keep separately saved manual Done.
                if workspace.doneAt == nil {
                    _ = store.send(.setWorkspaceDone(workspaceID: workspaceID, doneAt: doneAt))
                }
            } else if droppedOldRequest || record.cleanup?.kind == .merge {
                _ = store.send(.setWorkspaceDone(workspaceID: workspaceID, doneAt: nil))
            }
        }
        records.updateEach { record in
            guard record.release != nil else { return }
            if record.release?.preparationPullRequestURL == nil {
                Self.resetReleaseMerge(&record)
            }
            if record.cleanup?.kind == .merge { record.cleanup = nil }
        }
    }

    private static func resetReleaseMerge(_ record: inout TaskRecord) {
        record.mergedAt = nil
        record.mergeCommit = nil
        record.mergeTarget = nil
        record.mergeRequestedAt = nil
        record.mergeCancelledAt = nil
        record.mergeFailure = nil
        record.droppedMergeCleanupPullRequestURL = nil
    }

    // MARK: - Release

    /// `task.release`: makes a release task for a project. Its agent starts
    /// in a new worktree on no branch, at the remote default branch's
    /// commit fetched now, never in the project checkout, which can be old,
    /// dirty or on another branch. The agent gets `release_skill`,
    /// `release_prompt` and the project's To ship tasks. The agent confirms
    /// the release after all approved work and verification finish.
    /// `agent`, `model` and `effort` choose the release's agent, as for a
    /// create; `[defaults]` fills what they leave out.
    @discardableResult
    func release(
        workspaceID requestedWorkspaceID: UUID,
        caller: TaskCaller,
        agent: String? = nil,
        model: String? = nil,
        effort: String? = nil
    ) throws -> TaskRecord {
        let projectID = store.state.subspaceParentIDsByWorkspaceID()[requestedWorkspaceID] ?? requestedWorkspaceID
        guard let project = store.state.workspacesByID[projectID] else {
            throw TaskError("No open workspace has ID \(requestedWorkspaceID.uuidString).")
        }
        let root = try resolvedProjectRoot(workspaceID: projectID).path
        let config: TasksConfig
        do {
            config = try configLoader()
        } catch {
            throw TaskError(error.localizedDescription)
        }
        guard config.canRelease(projectRoot: root, repositoryRoot: releaseRepositoryRoot(projectRoot: root), homeDirectoryPath: homeDirectoryPath) else {
            throw TaskError("Set release_skill or release_prompt for \(root) in ~/.toastty/tasks.toml to release from Toastty.")
        }
        let releaseSkill = config.releaseSkill(forProjectRoot: root, repositoryRoot: releaseRepositoryRoot(projectRoot: root), homeDirectoryPath: homeDirectoryPath)
        let releasePrompt = config.releaseWorkspace(forProjectRoot: root, repositoryRoot: releaseRepositoryRoot(projectRoot: root), homeDirectoryPath: homeDirectoryPath)?.releasePrompt
        if let running = releaseUnderWay(projectRoot: root) {
            throw TaskError("A release of \(project.title) is already under way: \(running.title).")
        }
        let children = toShipTasks(projectRoot: root)
        let pinned = TaskFields(
            workspaceID: projectID,
            agent: agent.flatMap(taskNonEmpty),
            model: model.flatMap(taskNonEmpty),
            effort: effort.flatMap(taskNonEmpty),
            prompt: releasePrompt,
            skill: releaseSkill
        )
        let resolved = try resolvedFields(
            pinned: pinned,
            workspaceID: projectID,
            defaults: config.defaults
        )
        let day = Calendar.current.dateComponents([.year, .month, .day], from: now())
        let date = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        let slug = TaskRecord.uniqueSlug("release-\(date)", taken: Set(records.records.map(\.slug)))
        var lines = ["Release \(project.title)."]
        if children.isEmpty {
            lines.append("No merged task is waiting for a release.")
        } else {
            lines.append("These merged tasks are waiting for it:")
            for child in children {
                var line = "- \(CoordinatorTaskLink.markdown(taskID: child.id, title: child.title))"
                if let url = child.pullRequestURL { line += " — \(url)" }
                if let commit = child.mergeCommit { line += " (merge \(commit.prefix(12)))" }
                lines.append(line)
            }
        }
        lines.append("""
        After every approved lane and its verification finish, give your final report and run `toastty task release-complete --text-file <report.json>` as your last action. Write the file outside the worktree. The JSON lists each remote tag and the IDs from the task links it ships, for example `{"tags":[{"tag":"v1.2.3","taskIDs":[]}]}`. Use an empty taskIDs list for a tag that ships no tracked task. Report only tasks whose work was delivered by the listed tags. Keep the task open while any lane or background work remains.
        """)
        var record = TaskRecord(
            createdAt: now(),
            text: lines.joined(separator: "\n"),
            title: "Release \(project.title)",
            slug: slug,
            titleSetByUser: true,
            source: caller.source,
            pinned: pinned,
            resolved: resolved,
            workspaceID: projectID,
            projectRoot: root,
            setup: .settingUp,
            startWork: TaskStartWork(branchPrefix: "release", requestedAt: now(), detached: true)
        )
        record.release = TaskRelease(childTaskIDs: children.map(\.id))
        do {
            try records.insert(record)
        } catch {
            throw TaskError("Toastty could not save the task: \(error.localizedDescription)")
        }
        ToasttyLog.info("Started a release task", category: .tasks, metadata: [
            "task_id": record.id.uuidString,
            "project_root": root,
            "tasks": String(children.count),
        ])
        startSetup(taskID: record.id)
        return record
    }

    // MARK: - Release right after merge

    /// `task.set-release`: saves, or with `requested == false` clears, the
    /// user's request to release this task's work right after it merges.
    /// Toastty starts no release for it. Asking again keeps the first
    /// time, and clearing a task that has no request changes nothing. A
    /// request is refused where no merge of the task can still wait for a
    /// release: a Done or archived task, and a release task.
    @discardableResult
    func setReleaseAfterMerge(taskID: UUID, requested: Bool) throws -> TaskRecord {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        if requested {
            guard record.release == nil else {
                throw TaskError("Task \(record.title) is a release task, so it has no merge to release.")
            }
            guard record.archivedAt == nil else {
                throw TaskError("Task \(record.title) is archived.")
            }
            // The board knows a task that is Done without a mark of its own:
            // merged in a project without release tags, or finished through
            // its child tasks.
            let stage = board?.items().first { $0.taskID == taskID }?.stage
            guard record.doneAt == nil, record.shippedAt == nil, stage != .done else {
                throw TaskError("Task \(record.title) is done.")
            }
        }
        let requestedAt = now()
        try saveMergeState(taskID: taskID) { record in
            if requested == false {
                record.releaseAfterMerge = nil
            } else if record.releaseAfterMerge == nil {
                record.releaseAfterMerge = TaskReleaseAfterMerge(requestedAt: requestedAt)
            }
        }
        return records.record(id: taskID)!
    }

    /// Reuse saved checkout identity even after merge cleanup removed a worktree.
    /// A board also discovers projects whose tasks never made a worktree.
    func releaseRepositoryRoot(projectRoot root: String, record: TaskRecord? = nil) -> String {
        if let checkout = record?.operation.worktree?.checkoutRoot ?? board?.repositoryRoots[root] { return checkout }
        let normalized = TasksConfigFile.normalizedPath(root, homeDirectoryPath: homeDirectoryPath)
        return records.records.first {
            $0.projectRoot.map { TasksConfigFile.normalizedPath($0, homeDirectoryPath: homeDirectoryPath) == normalized } == true
                && $0.operation.worktree != nil
        }?.operation.worktree?.checkoutRoot ?? root
    }

    /// The project's release task that has not shipped or ended, if any.
    /// A project has one release at a time, whichever spelling of its path
    /// the release was made with.
    func releaseUnderWay(projectRoot root: String) -> TaskRecord? {
        let target = TasksConfigFile.normalizedPath(releaseRepositoryRoot(projectRoot: root), homeDirectoryPath: homeDirectoryPath)
        return records.records.first { record in
            guard record.release != nil, record.shippedAt == nil, record.archivedAt == nil, record.doneAt == nil,
                  let projectRoot = record.projectRoot else { return false }
            return TasksConfigFile.normalizedPath(releaseRepositoryRoot(projectRoot: projectRoot, record: record), homeDirectoryPath: homeDirectoryPath) == target
        }
    }

    /// The project's merged tasks that no release tag contains yet. A task
    /// that is To ship only because its child tasks are has no merge of its
    /// own, so its children stand for it.
    func toShipTasks(projectRoot root: String) -> [TaskRecord] {
        let repository = TasksConfigFile.normalizedPath(releaseRepositoryRoot(projectRoot: root), homeDirectoryPath: homeDirectoryPath)
        func sameRepository(_ record: TaskRecord) -> Bool {
            guard let project = record.projectRoot else { return false }
            return TasksConfigFile.normalizedPath(releaseRepositoryRoot(projectRoot: project, record: record), homeDirectoryPath: homeDirectoryPath) == repository
        }
        if let board {
            return board.items()
                .filter { $0.stage == .toShip && $0.finishedThroughChildren == false }
                .compactMap(\.record)
                .filter { sameRepository($0) && $0.release == nil }
        }
        return records.records.filter {
            sameRepository($0) && $0.release == nil && $0.mergedAt != nil && $0.mergeTarget?.waitsForRelease != false
                && $0.shippedAt == nil && $0.archivedAt == nil && $0.doneAt == nil
        }
    }

    // MARK: - Release monitor

    /// Accepts a final report only from the task's own release agent. Every
    /// reported tag and merge commit must check out before anything is saved.
    func reportReleaseCompletion(caller: TaskCaller, tags: [TaskRelease.Tag]) async throws -> TaskRecord {
        let record = try reportingRelease(caller)
        if let completion = record.release?.completion {
            guard tags == completion.tags else { throw TaskError("This release already has a different completion report.") }
            return record
        }
        guard tags.isEmpty == false, Set(tags.map(\.tag)).count == tags.count,
              tags.allSatisfy({ Set($0.taskIDs).count == $0.taskIDs.count }) else {
            throw TaskError("Report at least one remote tag. List each tag once and each task at most once per tag.")
        }
        guard let root = record.projectRoot else { throw TaskError("This release has no project directory.") }
        let checkout = try await worktreeCreator.checkout(for: releaseRepositoryRoot(projectRoot: root, record: record))
        guard let remote = checkout.remote else { throw TaskError("The release repository has no Git remote.") }
        let listed = try await worktreeCreator.git(["ls-remote", "--tags", remote], in: checkout.root)
        let remoteTags = Self.remoteTagCommits(listed.output)
        var taskMerges: [UUID: String] = [:]
        var taskTags: [UUID: String] = [:]
        for tag in tags {
            guard let commit = remoteTags[tag.tag] else { throw TaskError("The remote does not have tag \(tag.tag).") }
            try await requireCommit(commit, remote: remote, root: checkout.root, tag: tag.tag)
            for id in tag.taskIDs {
                let merge = try releaseMergeCommit(taskID: id, repositoryRoot: checkout.root)
                guard taskMerges[id].map({ $0 == merge }) ?? true,
                      try await containsCommit(merge, tagCommit: commit, root: checkout.root) else {
                    throw TaskError("Tag \(tag.tag) does not contain task \(id.uuidString)'s merge commit.")
                }
                taskMerges[id] = merge
                if taskTags[id] == nil { taskTags[id] = tag.tag }
            }
        }
        // Git awaited. The task, its owner or its listed merges may have changed.
        let current = try reportingRelease(caller)
        guard current.id == record.id, current.projectRoot == record.projectRoot else {
            throw TaskError("The release task changed while Toastty checked its tags.")
        }
        if let completion = current.release?.completion {
            guard tags == completion.tags else { throw TaskError("This release already has a different completion report.") }
            return current
        }
        for (id, merge) in taskMerges {
            guard try releaseMergeCommit(taskID: id, repositoryRoot: checkout.root) == merge else {
                throw TaskError("Task \(id.uuidString)'s merge changed while Toastty checked its tag.")
            }
        }
        let reportedAt = now()
        try records.saveEach { task in
            if task.id == current.id {
                task.release?.completion = TaskRelease.Completion(reportedAt: reportedAt, tags: tags)
            } else if let tag = taskTags[task.id], task.shippedAt == nil {
                task.shippedAt = reportedAt
                task.releaseTag = tag
            }
        }
        return records.record(id: current.id) ?? current
    }

    private func reportingRelease(_ caller: TaskCaller) throws -> TaskRecord {
        guard let workspaceID = caller.workspaceID, let sessionID = caller.sessionID,
              let record = records.record(taskSpaceWorkspaceID: workspaceID), record.release != nil,
              liveAgentSession(of: record, ownAgentOnly: true)?.sessionID == sessionID else {
            throw TaskError("Only the release task's own agent can report its completion.")
        }
        guard record.archivedAt == nil, record.doneAt == nil,
              record.shippedAt == nil || record.release?.completion != nil else {
            throw TaskError("This release task has already ended.")
        }
        return record
    }

    private func releaseMergeCommit(taskID: UUID, repositoryRoot: String) throws -> String {
        guard let task = records.record(id: taskID), task.release == nil,
              task.archivedAt == nil, task.doneAt == nil, task.mergedAt != nil,
              task.mergeTarget?.waitsForRelease != false,
              let root = task.projectRoot, let commit = task.mergeCommit,
              TasksConfigFile.normalizedPath(releaseRepositoryRoot(projectRoot: root, record: task), homeDirectoryPath: homeDirectoryPath)
                == TasksConfigFile.normalizedPath(repositoryRoot, homeDirectoryPath: homeDirectoryPath) else {
            throw TaskError("Task \(taskID.uuidString) is not a release-eligible merge of this repository.")
        }
        return commit
    }

    private func requireCommit(_ commit: String, remote: String, root: String, tag: String) async throws {
        guard (commit.count == 40 || commit.count == 64),
              commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw TaskError("The remote returned an invalid object ID for tag \(tag).")
        }
        func objectType() async throws -> String {
            try await worktreeCreator.git(["cat-file", "-t", commit], in: root, allowFailure: true)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if try await objectType() == "commit" { return }
        // Fetch only the advertised object. Leave local tags and FETCH_HEAD alone.
        try await worktreeCreator.git(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", remote, commit], in: root)
        guard try await objectType() == "commit" else { throw TaskError("Remote tag \(tag) does not point to a Git commit.") }
    }

    /// Automatic shipping is for ordinary merges outside a managed release,
    /// in projects that use a tag pattern as evidence for every change.
    func checkReleases() async {
        finishReportedReleases()
        guard isCheckingReleases == false else { return }
        isCheckingReleases = true
        defer { isCheckingReleases = false }
        guard let config = try? configLoader() else { return }
        let candidates = records.records.filter { record in
            guard record.release == nil, record.shippedAt == nil, record.archivedAt == nil,
                  record.doneAt == nil, record.projectRoot != nil else { return false }
            return record.mergedAt != nil && record.mergeCommit != nil && record.mergeTarget?.waitsForRelease != false
        }
        for (root, tasks) in Dictionary(grouping: candidates, by: { $0.projectRoot! }) {
            await checkReleases(root: root, config: config, tasks: tasks)
        }
    }

    private func checkReleases(root: String, config: TasksConfig, tasks: [TaskRecord]) async {
        let repository = releaseRepositoryRoot(projectRoot: root, record: tasks.first)
        guard let checkout = try? await worktreeCreator.checkout(for: repository),
              releaseUnderWay(projectRoot: checkout.root) == nil,
              let workspace = config.releaseWorkspace(forProjectRoot: root, repositoryRoot: checkout.root, homeDirectoryPath: homeDirectoryPath),
              workspace.releaseTracking != .reported, let pattern = workspace.releaseTags else { return }
        guard let remote = checkout.remote,
              let listed = try? await worktreeCreator.git(["ls-remote", "--tags", remote], in: checkout.root, allowFailure: true),
              listed.succeeded else {
            ToasttyLog.info("Release check skipped a project its remote did not answer for", category: .tasks, metadata: ["project_root": root])
            return
        }
        // The remote's own tags decide: local tags, which may be unpushed or
        // differ from the remote's, play no part. Fetching the branches,
        // without tags or FETCH_HEAD (start-work reads that under the
        // checkout's lock), brings the commits the tags name.
        _ = try? await worktreeCreator.git(
            ["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", remote],
            in: checkout.root,
            allowFailure: true
        )
        let tags = await releaseTags(Self.remoteTagCommits(listed.output), matching: pattern, in: checkout.root)
        for task in tasks {
            guard let commit = task.mergeCommit,
                  let tag = await firstTag(containing: commit, in: tags, root: checkout.root),
                  releaseUnderWay(projectRoot: checkout.root) == nil,
                  let current = records.record(id: task.id), current.mergeCommit == commit,
                  current.shippedAt == nil, current.archivedAt == nil, current.doneAt == nil,
                  current.mergeTarget?.waitsForRelease != false else { continue }
            records.update(id: task.id) {
                $0.shippedAt = self.now()
                $0.releaseTag = tag
            }
            ToasttyLog.info("A task shipped", category: .tasks, metadata: [
                "task_id": task.id.uuidString,
                "release_tag": tag,
            ])
        }
    }

    /// The remote's tags that match `pattern` and whose commits are here,
    /// oldest commit first.
    private func releaseTags(_ remoteTags: [String: String], matching pattern: String, in root: String) async -> [(name: String, commit: String)] {
        let matching = remoteTags.filter { fnmatch(pattern, $0.key, 0) == 0 }
        guard matching.isEmpty == false,
              let dated = try? await worktreeCreator.git(
                ["log", "--no-walk", "--ignore-missing", "--format=%H %ct"] + Array(Set(matching.values)),
                in: root,
                allowFailure: true
              ) else { return [] }
        var times: [String: Int] = [:]
        for line in dated.output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            if parts.count == 2, let time = Int(parts[1]) { times[String(parts[0])] = time }
        }
        struct Dated {
            var name: String
            var commit: String
            var time: Int
        }
        var ordered: [Dated] = []
        for (name, commit) in matching {
            if let time = times[commit] { ordered.append(Dated(name: name, commit: commit, time: time)) }
        }
        ordered.sort { (lhs: Dated, rhs: Dated) -> Bool in
            lhs.time != rhs.time ? lhs.time < rhs.time : lhs.name < rhs.name
        }
        return ordered.map { (name: $0.name, commit: $0.commit) }
    }

    /// The oldest of `tags` whose commit contains `commit`.
    private func firstTag(containing commit: String, in tags: [(name: String, commit: String)], root: String) async -> String? {
        for tag in tags {
            if (try? await containsCommit(commit, tagCommit: tag.commit, root: root)) == true {
                return tag.name
            }
        }
        return nil
    }

    private func containsCommit(_ commit: String, tagCommit: String, root: String) async throws -> Bool {
        if commit == tagCommit { return true }
        return try await worktreeCreator.git(
            ["merge-base", "--is-ancestor", commit, tagCommit], in: root, allowFailure: true
        ).succeeded
    }

    /// `git ls-remote --tags` output as tag name to commit. An annotated
    /// tag's peeled `^{}` line names its commit.
    static func remoteTagCommits(_ output: String) -> [String: String] {
        var commits: [String: String] = [:]
        var peeled: Set<String> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1].hasPrefix("refs/tags/") else { continue }
            var name = String(parts[1].dropFirst("refs/tags/".count))
            if name.hasSuffix("^{}") {
                name = String(name.dropLast(3))
                commits[name] = parts[0]
                peeled.insert(name)
            } else if peeled.contains(name) == false {
                commits[name] = parts[0]
            }
        }
        return commits
    }

    func releaseHasOutstandingWork(_ record: TaskRecord) -> Bool {
        if record.waiting != nil || record.replyRequest != nil || record.watches?.contains(where: \.isPending) == true { return true }
        guard let workspaceID = record.taskSpaceWorkspaceID, store.state.workspacesByID[workspaceID] != nil else { return false }
        guard let sessions else { return true }
        return sessions.activeSessions(workspaceID: workspaceID).contains { $0.isInTurn || $0.hasBackgroundWork }
    }

    /// An old tag-derived shipped record is never sufficient for teardown.
    func finishReportedReleases() {
        guard isTerminating == false else { return }
        for record in records.records where record.archivedAt == nil && record.doneAt == nil && record.cleanup == nil {
            guard record.release?.completion != nil, releaseHasOutstandingWork(record) == false else { continue }
            startTeardown(taskID: record.id, kind: .release, options: TaskArchiveOptions())
        }
    }
}
