import CoreState
import Foundation

/// The coordinator as a destination of task events.
///
/// The same detector that feeds the webhooks feeds it, so the 3-second
/// hold, the catch-up after a relaunch and the saved baseline apply
/// unchanged. Instead of a request for each event, the changes wait in one
/// digest (`CoordinatorWakeState`), saved in the outbox file. Each pass
/// offers the digest to `CoordinatorController.send` without queueing: it
/// is typed only at an open prompt, and counts as told only when it was
/// typed. Until then it waits here and grows.
///
/// A change that wakes nothing on its own, such as a task that starts
/// running, goes idle or is Done, waits without starting a digest; see
/// `CoordinatorWakeState` for the changes that wake. The coordinator can
/// watch a task or a project, so that a merge or an end it waits for wakes
/// it.
///
/// The pass also reads each open task's alerts (`TaskAlert`) with its own
/// clock, so an alert that only time raises, such as an agent that has
/// been silent for 30 minutes, starts within about a second. Alerts are
/// part of the detector's key, so they settle, are saved and survive a
/// relaunch as a stage does. No webhook event reads them.
///
/// The coordinator's timer is part of the same state. It runs only for a
/// time the coordinator set. A timer that came due adds one line to the
/// digest, or is a digest of its own.
///
/// A wake turn that found nothing for the user is marked quiet with the
/// same command that sets the timer. The mark is saved with the digest it
/// belongs to, so the chat folds that turn also after a relaunch, and the
/// end of the turn alerts nobody (`SessionRuntimeStore`).
extension TaskWebhookService {
    /// The coordinator's next check, as it asks for it.
    enum CoordinatorWakeRequest: Equatable {
        case after(TimeInterval)
        case at(Date)
        /// Removes the time the coordinator set: no timer runs.
        case clear
    }

    struct CoordinatorWakeStatus: Equatable {
        /// The tasks whose changes wait for the next digest, also the
        /// changes that wake nothing on their own.
        var pendingTaskCount: Int
        /// The time the coordinator set for its next check. `nil` when it
        /// set none: then no timer runs.
        var nextWakeAt: Date?
        var lastWakeAt: Date
        var watchedTaskIDs: [UUID]
        var watchedProjectRoots: [String]
    }

    /// What the coordinator watches.
    enum CoordinatorWatchTarget: Equatable {
        case task(UUID)
        /// A project root, as `TasksConfigFile.normalizedPath` writes it.
        case project(root: String)
    }

    /// Gives the service the app's coordinator. From then on it follows
    /// tasks while a coordinator workspace exists.
    func attach(coordinator: CoordinatorController) {
        self.coordinator = coordinator
        coordinator.onWorkspaceChange = { [weak self] workspaceID in
            self?.coordinatorWorkspaceChanged(to: workspaceID)
        }
        coordinator.isQuietDigest = { [weak self] text in
            self?.coordinatorWake?.isQuietDigest(text) ?? false
        }
        coordinatorWorkspaceChanged(to: coordinator.location?.workspaceID)
    }

    private func coordinatorWorkspaceChanged(to workspaceID: UUID?) {
        let before = coordinatorWake
        let detectorBefore = detector
        followCoordinator(workspaceID: workspaceID, at: now())
        if coordinatorWake != before || detector != detectorBefore { saveOutbox() }
        updatePolling()
    }

    /// Keeps the wake state with the coordinator's workspace. What waited
    /// for a coordinator that closed is dropped: a coordinator opened later
    /// starts with nothing waiting and no timer.
    func followCoordinator(at: Date) {
        followCoordinator(workspaceID: coordinator?.location?.workspaceID, at: at)
    }

    private func followCoordinator(workspaceID: UUID?, at: Date) {
        guard workspaceID != coordinatorWake?.workspaceID else { return }
        coordinatorWake = workspaceID.map { CoordinatorWakeState(workspaceID: $0, startedAt: at) }
        guard workspaceID != nil else { return }
        // As for a first webhook: when nothing followed the tasks until
        // now, the detector starts from now. With a webhook that keeps it
        // running, the new state's first look tells nothing instead
        // (`CoordinatorWakeState.isFollowing`). Either way, a change from
        // before the coordinator existed is not told.
        if webhooks.contains(where: isActive) == false {
            detector.reset()
        }
        ToasttyLog.info("Task changes now wake the coordinator", category: .tasks)
    }

    /// Sets the alerts of every open task in `states`. While Toastty cannot
    /// read the checks, as before GitHub's first answer after a launch, the
    /// check alerts the detector last counted stay, so a relaunch does not
    /// tell them again.
    func addAlerts(to states: inout [UUID: TaskWebhookTaskState], at: Date) {
        let open = Set(states.compactMap { id, state in
            state.key.group == "\(TaskStage.Group.done)" || state.key.group == "\(TaskStage.Group.archived)" ? nil : id
        })
        guard open.isEmpty == false else { return }
        for (id, facts) in taskAlertFacts(open) where open.contains(id) {
            states[id]?.key.alerts = facts.alerts(now: at, previous: detector.baseline?[id]?.key.alerts ?? [])
        }
    }

    /// Types the digest when one waits and the coordinator's prompt is
    /// open. A coordinator that works, has the user's draft, starts or
    /// does not run gets nothing: the digest stays here.
    func wakeCoordinator(at: Date) {
        guard let coordinator, var wake = coordinatorWake, let digest = wake.digest(now: at) else { return }
        guard let result = try? coordinator.send(digest, queueWhenHeld: false), result.wasTyped else { return }
        let taskCount = wake.changes.count
        wake.markDelivered(digest, at: at)
        coordinatorWake = wake
        // Saved at once: after a quit, a digest that was typed is not
        // typed again.
        saveOutbox()
        ToasttyLog.info("Typed a wake digest into the coordinator", category: .tasks, metadata: [
            "task_count": String(taskCount),
            "submit_confirmed": result == .sent ? "true" : "false",
        ])
    }

    /// Sets, moves or removes the coordinator's next check. With `quiet`,
    /// it also marks the turn that runs now as one that needs nothing from
    /// the user. That is refused, and nothing changes, unless the last
    /// digest started this turn and no other message came into it.
    @discardableResult
    func setCoordinatorWake(_ request: CoordinatorWakeRequest, quiet: Bool = false) throws -> CoordinatorWakeStatus {
        let at = now()
        followCoordinator(at: at)
        guard var wake = coordinatorWake else {
            throw CoordinatorError("There is no coordinator. Open it first.")
        }
        let date: Date? = switch request {
        case .after(let seconds): at.addingTimeInterval(seconds)
        case .at(let date): date
        case .clear: nil
        }
        if let date, date.timeIntervalSince(at) < CoordinatorWakeState.minimumDelay {
            throw CoordinatorError("The next check must be at least 1 minute from now.")
        }
        if quiet {
            guard let digestKey = wake.lastDigestKey,
                  coordinator?.runsOnlyTheTurn(ofDigestKey: digestKey) == true else {
                throw CoordinatorError(
                    "Only a turn that Toastty's last wake started, with no other message in it, can be quiet. "
                        + "Nothing changed. Run the command again without --quiet, and answer as usual."
                )
            }
            wake.markLastDigestQuiet()
        }
        // Whole seconds, as the digest and the status print the time.
        wake.setRequestedWake(date.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.up)) })
        coordinatorWake = wake
        saveOutbox()
        if quiet {
            ToasttyLog.info("Marked a coordinator wake turn quiet", category: .tasks)
        }
        return status(of: wake)
    }

    /// Starts or ends a watch of the coordinator's. A task's merge or end,
    /// or any merge in a project, then wakes the coordinator; see
    /// `CoordinatorWakeState`. Watching again what it watches changes
    /// nothing.
    @discardableResult
    func setCoordinatorWatch(_ target: CoordinatorWatchTarget, watching: Bool) throws -> CoordinatorWakeStatus {
        followCoordinator(at: now())
        guard var wake = coordinatorWake else {
            throw CoordinatorError("There is no coordinator. Open it first.")
        }
        switch (target, watching) {
        case (.task(let taskID), true):
            guard wake.watch(taskID: taskID) else {
                throw CoordinatorError("The coordinator already watches \(CoordinatorWakeState.maximumWatches) tasks.")
            }
        case (.task(let taskID), false):
            wake.unwatch(taskID: taskID)
        case (.project(let root), true):
            guard wake.watch(projectRoot: root) else {
                throw CoordinatorError("The coordinator already watches \(CoordinatorWakeState.maximumWatches) projects.")
            }
        case (.project(let root), false):
            wake.unwatch(projectRoot: root)
        }
        if wake != coordinatorWake {
            coordinatorWake = wake
            saveOutbox()
        }
        return status(of: wake)
    }

    /// `nil` when there is no coordinator.
    var coordinatorWakeStatus: CoordinatorWakeStatus? {
        guard let wake = coordinatorWake, wake.workspaceID == coordinator?.location?.workspaceID else { return nil }
        return status(of: wake)
    }

    private func status(of wake: CoordinatorWakeState) -> CoordinatorWakeStatus {
        CoordinatorWakeStatus(
            pendingTaskCount: wake.changes.count,
            nextWakeAt: wake.requestedWakeAt,
            lastWakeAt: wake.lastWakeAt,
            watchedTaskIDs: wake.watchedTaskIDs,
            watchedProjectRoots: wake.watchedProjectRoots
        )
    }
}
