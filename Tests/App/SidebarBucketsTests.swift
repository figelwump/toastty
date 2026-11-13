import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// The rules that place sidebar rows in Needs you, Running and Idle, and
/// that keep the selected row from moving under the pointer.
@MainActor
struct SidebarBucketsTests {
    private typealias Candidate = SidebarBucketCandidate<String>

    /// A row named `name`, keyed by its name so that tests can refer to it.
    private func row(_ name: String, _ bucket: SidebarBucket, parent: String? = nil) -> Candidate {
        Candidate(key: key(name), bucket: bucket, parent: parent.map(key), payload: name)
    }

    private func key(_ name: String) -> SidebarRowKey {
        let bits = String(format: "%016lx", UInt(bitPattern: name.hashValue))
        return .task(.task(UUID(uuidString: "00000000-0000-0000-\(bits.prefix(4))-\(bits.dropFirst(4))")!))
    }

    private func names(_ entries: [SidebarBucketEntry<String>]) -> [String] {
        entries.map { entry in
            (entry.isLinkedChild ? "  " : "") + entry.payload + (entry.isContext ? " (dimmed)" : "")
                + (entry.listsApartFromParent ? " ↖" : "")
        }
    }

    private func subspace(status: SidebarSubspacePresentation.RowStatus, stage: TaskStage?) -> SidebarSubspacePresentation.Row {
        SidebarSubspacePresentation.Row(
            id: UUID(), title: "Task", status: status, stage: stage, annotations: [:], summary: nil,
            spawningSessionID: nil, spawnerName: nil, sessions: []
        )
    }

    @Test func sessionsGoWhereTheirStateAsksForTheUser() {
        #expect(SidebarBucket.session(kind: .needsApproval, isUnread: false) == .needsYou)
        #expect(SidebarBucket.session(kind: .error, isUnread: false) == .needsYou)
        #expect(SidebarBucket.session(kind: .ready, isUnread: true) == .needsYou)
        // A finished turn that was read waits at the prompt.
        #expect(SidebarBucket.session(kind: .ready, isUnread: false) == .idle)
        #expect(SidebarBucket.session(kind: .working, isUnread: false) == .running)
        #expect(SidebarBucket.session(kind: .idle, isUnread: false) == .idle)
        // A sub-agent that waits for an approval puts its parent session in Needs you.
        #expect(SidebarBucket.session(kind: .working, isUnread: false, childNeedsAttention: true) == .needsYou)
    }

    @Test func taskSpacesTakeTheMoreUrgentOfTheirSessionsAndTheirStage() {
        // A failed setup needs the user although no agent asks anything.
        #expect(SidebarBucket.subspace(subspace(status: .idle, stage: .needsYou(.setupFailed(reason: "x")))) == .needsYou)
        #expect(SidebarBucket.subspace(subspace(status: .question, stage: .needsYou(.awaitingReply))) == .needsYou)
        #expect(SidebarBucket.subspace(subspace(status: .review, stage: .needsYou(.review))) == .needsYou)
        #expect(SidebarBucket.subspace(subspace(status: .working, stage: .starting)) == .running)
        #expect(SidebarBucket.subspace(subspace(status: .idle, stage: .idle)) == .idle)
        // A working agent in a merged task space keeps the row in Running.
        #expect(SidebarBucket.subspace(subspace(status: .working, stage: .toShip)) == .running)
        // A subspace without a task uses its sessions only.
        #expect(SidebarBucket.subspace(subspace(status: .ready, stage: nil)) == .needsYou)
        #expect(SidebarBucket.subspace(subspace(status: .idle, stage: nil)) == .idle)
    }

    @Test func familiesListTogetherInTheMostUrgentBucketAndRowsKeepTheirOrder() {
        let candidates = [
            row("Plaid session", .idle),
            row("Parent", .running),
            row("Child asks", .needsYou, parent: "Parent"),
            row("Child idle", .idle, parent: "Parent"),
            row("Grandchild", .needsYou, parent: "Child asks"),
            row("Waitlist", .needsYou),
            row("Deploy", .running),
        ]
        let layout = SidebarBuckets.layout(candidates, pin: nil)
        // One level only: the grandchild lists as a row of its own.
        #expect(names(layout.entries(.needsYou)) == [
            "Parent (dimmed)", "  Child asks", "  Child idle (dimmed)", "Grandchild", "Waitlist",
        ])
        #expect(names(layout.entries(.running)) == ["Deploy"])
        #expect(names(layout.entries(.idle)) == ["Plaid session"])
        // Counts follow each row's own state, not where its family lists.
        #expect(SidebarBuckets.counts(candidates) == [.needsYou: 3, .running: 2, .idle: 2])
    }

    @Test func theSelectedRowHoldsWhileItsTurnIsReadAndMovesWhenWorkResumes() {
        var candidates = [row("Thumbnail", .needsYou), row("Hostname", .needsYou), row("Deploy", .running)]
        var layout = SidebarBuckets.layout(candidates, pin: nil)
        #expect(names(layout.entries(.needsYou)) == ["Thumbnail", "Hostname"])

        // Selecting the row reads it: it holds in Needs you, dimmed.
        var pin = SidebarBuckets.pin(previous: nil, selected: key("Thumbnail"), displayed: layout.displayed)
        candidates[0] = row("Thumbnail", .idle)
        layout = SidebarBuckets.layout(candidates, pin: pin)
        #expect(names(layout.entries(.needsYou)) == ["Thumbnail (dimmed)", "Hostname"])
        #expect(layout.entries(.idle).isEmpty)

        // Work resuming moves it to Running at once, in its place.
        pin = SidebarBuckets.pin(previous: layout.pin, selected: key("Thumbnail"), displayed: layout.displayed)
        candidates[0] = row("Thumbnail", .running)
        layout = SidebarBuckets.layout(candidates, pin: pin)
        #expect(names(layout.entries(.running)) == ["Thumbnail", "Deploy"])

        // Back at the prompt while still selected: it holds in Running.
        pin = SidebarBuckets.pin(previous: layout.pin, selected: key("Thumbnail"), displayed: layout.displayed)
        candidates[0] = row("Thumbnail", .idle)
        layout = SidebarBuckets.layout(candidates, pin: pin)
        #expect(names(layout.entries(.running)) == ["Thumbnail (dimmed)", "Deploy"])

        // Another selection releases it to Idle.
        pin = SidebarBuckets.pin(previous: layout.pin, selected: key("Hostname"), displayed: layout.displayed)
        layout = SidebarBuckets.layout(candidates, pin: pin)
        #expect(names(layout.entries(.idle)) == ["Thumbnail"])
    }

    @Test func aHeldRowStillMovesToAMoreUrgentBucket() {
        var candidates = [row("Deploy", .idle), row("Other", .idle)]
        var layout = SidebarBuckets.layout(candidates, pin: nil)
        let pin = SidebarBuckets.pin(previous: nil, selected: key("Deploy"), displayed: layout.displayed)
        candidates[0] = row("Deploy", .needsYou)
        layout = SidebarBuckets.layout(candidates, pin: pin)
        #expect(names(layout.entries(.needsYou)) == ["Deploy"])
        #expect(layout.pin == SidebarBucketPin(key: key("Deploy"), bucket: .needsYou))
    }

    @Test func aSelectedParentFollowsItsFamilyWhileItWorks() {
        var candidates = [row("Parent", .needsYou), row("Child", .needsYou, parent: "Parent")]
        var layout = SidebarBuckets.layout(candidates, pin: nil)
        var pin = SidebarBuckets.pin(previous: nil, selected: key("Parent"), displayed: layout.displayed)

        // The selected parent starts work; its child still needs the user.
        candidates[0] = row("Parent", .running)
        layout = SidebarBuckets.layout(candidates, pin: pin)
        #expect(names(layout.entries(.needsYou)) == ["Parent (dimmed)", "  Child"])

        // The child calms while the parent stays selected: the family moves
        // to Running with the working parent.
        pin = SidebarBuckets.pin(previous: layout.pin, selected: key("Parent"), displayed: layout.displayed)
        candidates[1] = row("Child", .idle, parent: "Parent")
        layout = SidebarBuckets.layout(candidates, pin: pin)
        #expect(names(layout.entries(.running)) == ["Parent", "  Child (dimmed)"])
        #expect(layout.entries(.needsYou).isEmpty)
    }

    @Test func needsYouListsOnlyRowsThatNeedTheUser() {
        let candidates = [
            row("Calm parent", .running),
            row("Asking child", .needsYou, parent: "Calm parent"),
            row("Asking parent", .needsYou),
            row("Asking child 2", .needsYou, parent: "Asking parent"),
            row("Idle child", .idle, parent: "Asking parent"),
            row("Child of another project", .needsYou, parent: "Elsewhere"),
            row("Idle", .idle),
        ]
        let list = SidebarBuckets.needsYou(candidates, pin: nil)
        // A child lists under its parent only when both need the user, and
        // no row lists dimmed.
        #expect(names(list.entries) == [
            "Asking child ↖", "Asking parent", "  Asking child 2", "Child of another project ↖",
        ])
    }

    @Test func needsYouHoldsTheSelectedRowUntilTheSelectionMovesOrWorkResumes() {
        var candidates = [row("Thumbnail", .needsYou), row("Hostname", .needsYou)]
        var list = SidebarBuckets.needsYou(candidates, pin: nil)
        var pin = SidebarBuckets.pin(previous: nil, selected: key("Thumbnail"), displayed: list.displayed)

        candidates[0] = row("Thumbnail", .idle)
        list = SidebarBuckets.needsYou(candidates, pin: pin)
        #expect(names(list.entries) == ["Thumbnail (dimmed)", "Hostname"])

        // Selecting another row lets it go.
        pin = SidebarBuckets.pin(previous: list.pin, selected: key("Hostname"), displayed: list.displayed)
        list = SidebarBuckets.needsYou(candidates, pin: pin)
        #expect(names(list.entries) == ["Hostname"])

        // A held row that starts work leaves at once.
        candidates = [row("Thumbnail", .needsYou), row("Hostname", .needsYou)]
        list = SidebarBuckets.needsYou(candidates, pin: nil)
        pin = SidebarBuckets.pin(previous: nil, selected: key("Thumbnail"), displayed: list.displayed)
        candidates[0] = row("Thumbnail", .running)
        list = SidebarBuckets.needsYou(candidates, pin: pin)
        #expect(names(list.entries) == ["Hostname"])
    }
}
