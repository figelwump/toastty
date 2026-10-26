import CoreState
import Darwin
import Foundation

extension TaskCoordinator {
    static let releaseCheckInterval: Duration = .seconds(15 * 60)

    // MARK: - Release

    /// `task.release`: makes a release task for a project. Its agent starts
    /// in a new worktree on no branch, at the remote default branch's
    /// commit fetched now, never in the project checkout, which can be old,
    /// dirty or on another branch. The agent gets `release_skill`,
    /// `release_prompt` and the project's To ship tasks. Shipping is detected from release tags, not
    /// from the agent, so a release made outside Toastty counts too.
    @discardableResult
    func release(workspaceID requestedWorkspaceID: UUID, caller: TaskCaller) throws -> TaskRecord {
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
        guard config.canRelease(projectRoot: root, homeDirectoryPath: homeDirectoryPath) else {
            throw TaskError("Set release_skill or release_prompt for \(root) in ~/.toastty/tasks.toml to release from Toastty.")
        }
        let releaseSkill = config.releaseSkill(forProjectRoot: root, homeDirectoryPath: homeDirectoryPath)
        let releasePrompt = config.workspace(forProjectRoot: root, homeDirectoryPath: homeDirectoryPath)?.releasePrompt
        if let running = releaseUnderWay(projectRoot: root) {
            throw TaskError("A release of \(project.title) is already under way: \(running.title).")
        }
        let children = toShipTasks(projectRoot: root)
        let resolved = try resolvedFields(
            pinned: TaskFields(prompt: releasePrompt, skill: releaseSkill),
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
                var line = "- \(child.title)"
                if let url = child.pullRequestURL { line += " — \(url)" }
                if let commit = child.mergeCommit { line += " (merge \(commit.prefix(12)))" }
                lines.append(line)
            }
        }
        var record = TaskRecord(
            createdAt: now(),
            text: lines.joined(separator: "\n"),
            title: "Release \(project.title)",
            slug: slug,
            titleSetByUser: true,
            source: caller.source,
            pinned: TaskFields(workspaceID: projectID, prompt: releasePrompt, skill: releaseSkill),
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

    /// The project's release task that has not shipped or ended, if any.
    /// A project has one release at a time, whichever spelling of its path
    /// the release was made with.
    func releaseUnderWay(projectRoot root: String) -> TaskRecord? {
        let target = TasksConfigFile.normalizedPath(root, homeDirectoryPath: homeDirectoryPath)
        return records.records.first { record in
            guard record.release != nil, record.shippedAt == nil, record.archivedAt == nil, record.doneAt == nil,
                  let projectRoot = record.projectRoot else { return false }
            return TasksConfigFile.normalizedPath(projectRoot, homeDirectoryPath: homeDirectoryPath) == target
        }
    }

    /// Whether the task keeps its task space and worktree after its merge,
    /// so the user can still look at them: its project has `release_tags`,
    /// and the task has not shipped or been marked done. A release task
    /// never waits. When tasks.toml cannot be read, the last version the
    /// board read decides, as it does for the stage the task shows.
    func waitsForRelease(_ record: TaskRecord) -> Bool {
        guard record.release == nil, record.shippedAt == nil, record.doneAt == nil,
              let root = record.projectRoot ?? record.workspaceID.flatMap({ store.state.workspacesByID[$0]?.rootDirectory }),
              let config = (try? configLoader()) ?? board?.config else { return false }
        return config.workspace(forProjectRoot: root, homeDirectoryPath: homeDirectoryPath)?.releaseTags != nil
    }

    /// The project's merged tasks that no release tag contains yet.
    func toShipTasks(projectRoot root: String) -> [TaskRecord] {
        if let board {
            return board.items()
                .filter { $0.stage == .toShip }
                .compactMap(\.record)
                .filter { $0.projectRoot == root && $0.release == nil }
        }
        return records.records.filter {
            $0.projectRoot == root && $0.release == nil && $0.mergedAt != nil
                && $0.shippedAt == nil && $0.archivedAt == nil && $0.doneAt == nil
        }
    }

    // MARK: - Release monitor

    /// Looks for release tags that contain the To ship tasks' merge
    /// commits and the release tasks' commits, in every project with
    /// `release_tags`. Only the remote's tags count: a tag that exists only
    /// here was not released. A shipped task then closes its task space and
    /// removes its worktree, once its agent is at rest: a release task with
    /// its own steps, and a merged task with the cleanup its merge left
    /// for the release.
    func checkReleases() async {
        guard isCheckingReleases == false else { return }
        isCheckingReleases = true
        defer { isCheckingReleases = false }
        guard let config = try? configLoader() else { return }
        let candidates = records.records.filter { record in
            guard record.shippedAt == nil, record.archivedAt == nil, record.projectRoot != nil else { return false }
            if record.release != nil {
                return record.setup.isStarted && record.operation.base != nil
            }
            return record.mergedAt != nil && record.mergeCommit != nil
        }
        for (root, tasks) in Dictionary(grouping: candidates, by: { $0.projectRoot! }) {
            guard let pattern = config.workspace(forProjectRoot: root, homeDirectoryPath: homeDirectoryPath)?.releaseTags else { continue }
            await checkReleases(root: root, pattern: pattern, tasks: tasks)
        }
        cleanUpShippedReleases()
        cleanUpShippedMergedTasks()
    }

    private func checkReleases(root: String, pattern: String, tasks: [TaskRecord]) async {
        guard let checkout = try? await worktreeCreator.checkout(for: root), let remote = checkout.remote,
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
            guard let commit = task.release != nil ? task.operation.base?.sha : task.mergeCommit,
                  let tag = await firstTag(containing: commit, in: tags, root: checkout.root) else { continue }
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
            if tag.commit == commit { return tag.name }
            if let result = try? await worktreeCreator.git(
                ["merge-base", "--is-ancestor", commit, tag.commit],
                in: root,
                allowFailure: true
            ), result.succeeded {
                return tag.name
            }
        }
        return nil
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

    /// Runs the cleanup after the merge for merged tasks that kept their
    /// task space while they waited for the release, now that it shipped.
    /// A task whose agent is working waits for the next check.
    private func cleanUpShippedMergedTasks() {
        let shipped = records.records.filter { record in
            guard record.release == nil, record.shippedAt != nil, record.mergedAt != nil, record.cleanup == nil,
                  let taskSpaceID = record.taskSpaceWorkspaceID,
                  store.state.workspacesByID[taskSpaceID] != nil else { return false }
            return agentInTurn(workspaceID: taskSpaceID) == false
        }
        cleanUpMergedTasks(shipped.map(\.id))
    }

    /// Closes the task spaces of shipped releases whose agents are at rest.
    private func cleanUpShippedReleases() {
        for record in records.records where record.release != nil && record.shippedAt != nil && record.cleanup == nil {
            if let taskSpaceID = record.taskSpaceWorkspaceID,
               store.state.workspacesByID[taskSpaceID] != nil,
               agentInTurn(workspaceID: taskSpaceID) {
                continue
            }
            startTeardown(taskID: record.id, kind: .release, options: TaskArchiveOptions())
        }
    }
}
