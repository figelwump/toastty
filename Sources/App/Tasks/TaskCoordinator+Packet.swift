import CoreState
import Foundation

/// A packet checked against the task and its screenshot files, ready to
/// store. Made in the request's context; the files are copied later, off
/// the main thread.
struct TaskPacketPublishPreparation {
    var taskID: UUID
    var packet: TaskPacket
    var screenshots: [(screenshot: TaskPacket.Screenshot, path: String)]
}

/// A stored packet, with what the worktree looks like now.
struct TaskPacketReading {
    var packet: TaskPacket
    /// The newest version the task has; `packet` may be an older one.
    var latestVersion: Int?
    /// The worktree's HEAD now; `nil` without a worktree, or when git
    /// could not read it.
    var currentHead: String?
    var stale: Bool
}

extension TaskCoordinator {
    // MARK: - Publish

    /// `task.packet.publish`, the checks: the task can take a packet, the
    /// packet is complete, and each screenshot it names was given as a
    /// readable file.
    func preparePacketPublish(taskID: UUID, packetJSON: Data, screenshotPaths: [String]) throws -> TaskPacketPublishPreparation {
        try checkCanTakePacket(taskID: taskID)
        do {
            let packet = try TaskPacket.parseDraft(packetJSON)
            let fileManager = fileManager
            let screenshots = try packet.matchScreenshots(files: screenshotPaths) { path in
                guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      fileManager.isReadableFile(atPath: path) else { return nil }
                return (attributes[.size] as? NSNumber)?.intValue
            }
            return TaskPacketPublishPreparation(taskID: taskID, packet: packet, screenshots: screenshots)
        } catch let error as TaskPacketError {
            throw TaskError(error.message)
        }
    }

    /// Reads the worktree's commit, stores the packet as the next version
    /// with its screenshots, then records the version on the task and
    /// marks it ready for review, as `task.ready-for-review` does, so it
    /// waits in Needs you.
    func finishPacketPublish(_ preparation: TaskPacketPublishPreparation) async throws -> (TaskRecord, TaskPacket) {
        let taskID = preparation.taskID
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        var packet = preparation.packet
        packet.createdAt = now()
        packet.headCommit = await worktreeHead(of: record)
        let store = packets
        let screenshots = preparation.screenshots
        let recordedVersion = record.packetVersion
        let stored: TaskPacket
        do {
            stored = try await Task.detached(priority: .userInitiated) {
                try store.write(packet, taskID: taskID, screenshots: screenshots, atLeastAfter: recordedVersion)
            }.value
        } catch {
            throw TaskError("Toastty could not store the packet: \(error.localizedDescription)")
        }
        let version = stored.version ?? 0
        // The task may have been deleted, archived or cleaned up while git
        // and the copies ran.
        do {
            try checkCanTakePacket(taskID: taskID)
        } catch {
            try? fileManager.removeItem(at: packets.versionDirectoryURL(taskID: taskID, version: version))
            throw error
        }
        do {
            try saveMergeState(taskID: taskID) {
                // Two publishes at once each store their own version; the
                // record keeps the newer one whichever saves last.
                guard version >= ($0.packetVersion ?? 0) else { return }
                $0.packetVersion = version
                $0.packetHeadCommit = stored.headCommit
                $0.readyForReviewAt = self.now()
            }
        } catch {
            try? fileManager.removeItem(at: packets.versionDirectoryURL(taskID: taskID, version: version))
            throw error
        }
        ToasttyLog.info("Published a task's review packet", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "version": String(version),
        ])
        return (records.record(id: taskID)!, stored)
    }

    /// A packet goes only to a task that exists, is not archived, and still
    /// has its files: once retention removed them, nothing would remove a
    /// new packet again.
    private func checkCanTakePacket(taskID: UUID) throws {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        guard record.archivedAt == nil else {
            throw TaskError("Task \(record.title) is archived.")
        }
        guard record.attachmentsRemovedAt == nil else {
            throw TaskError("Task \(record.title) finished more than a week ago, and Toastty removed its files.")
        }
    }

    // MARK: - Get

    /// `task.packet.get`: a stored packet, the newest unless `version`
    /// names one, and whether commits landed in the worktree since the
    /// newest one was published.
    func packet(taskID: UUID, version: Int?) async throws -> TaskPacketReading {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        guard let latest = record.packetVersion else {
            throw TaskError("Task \(record.title) has no packet. Its agent publishes one with toastty task packet publish.")
        }
        if record.attachmentsRemovedAt != nil {
            throw TaskError("Toastty removed the packets of task \(record.title) a week after it finished.")
        }
        if let version, version < 1 || version > latest {
            throw TaskError("Task \(record.title) has packets v1 to v\(latest).")
        }
        let store = packets
        let packet: TaskPacket
        do {
            packet = try await Task.detached(priority: .userInitiated) {
                try store.read(taskID: taskID, version: version ?? latest)
            }.value
        } catch let error as TaskPacketError {
            throw TaskError(error.message)
        }
        let currentHead = await worktreeHead(of: record)
        // Staleness compares the newest packet's commit: an older version
        // is superseded whether or not the worktree moved.
        return TaskPacketReading(
            packet: packet,
            latestVersion: latest,
            currentHead: currentHead,
            stale: record.packetIsStale(currentHead: currentHead)
        )
    }

    /// The task's worktree's commit, or `nil` when it has no worktree or
    /// git cannot read it, for example after the worktree was removed.
    private func worktreeHead(of record: TaskRecord) async -> String? {
        guard let worktree = record.worktree, fileManager.fileExists(atPath: worktree.path) else { return nil }
        guard let result = try? await worktreeCreator.git(["rev-parse", "--verify", "HEAD"], in: worktree.path, allowFailure: true),
              result.succeeded else { return nil }
        let head = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? nil : head
    }
}
