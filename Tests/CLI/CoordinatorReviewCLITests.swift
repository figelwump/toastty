import CoreState
import Foundation
import Testing
@testable import ToasttyCLIKit

struct CoordinatorReviewCLITests {
    @Test func publishResolvesEvidencePathsAndDoesNotExposeApproval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-cli-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let brief = "{\"behaviorChange\":\"Fixed\",\"decisionNeeded\":\"Review\",\"recommendation\":\"Approve\"}"
        try brief.write(to: root.appendingPathComponent("brief.json"), atomically: true, encoding: .utf8)
        let task = UUID()
        let invocation = try ToasttyCLI.parse(arguments: [
            "coordinator", "review", "publish", task.uuidString, "--head", String(repeating: "a", count: 40),
            "--base", "main", "--brief-file", "brief.json", "--evidence-file", "0=report.md",
        ], environment: ["PWD": root.path])
        guard case .appControlRun(.action, "coordinator.review.publish", let args) = invocation.command else {
            Issue.record("Expected review publication")
            return
        }
        #expect(args["taskID"] == .string(task.uuidString))
        #expect(args["brief"] == .string(brief))
        #expect(args["evidenceFiles"] == .array([.object(["evidenceIndex": .int(0), "filePath": .string(root.appendingPathComponent("report.md").path)])]))
        #expect(throws: ToasttyCLIError.self) {
            try ToasttyCLI.parse(arguments: ["coordinator", "review", "approve", UUID().uuidString], environment: [:])
        }
    }

    @Test func getListAndReportMapToStructuredContracts() throws {
        let review = UUID().uuidString
        let intent = UUID().uuidString
        let get = try ToasttyCLI.parse(arguments: ["coordinator", "review", "get", review], environment: [:])
        #expect(get.command == .appControlRun(kind: .query, id: "coordinator.review.get", args: ["reviewID": .string(review)]))
        let list = try ToasttyCLI.parse(arguments: ["coordinator", "review", "list"], environment: [:])
        #expect(list.command == .appControlRun(kind: .query, id: "coordinator.review.list", args: [:]))
        let report = try ToasttyCLI.parse(arguments: ["coordinator", "review", "report", review, "--intent", intent, "--outcome", "blocked", "--detail", "Resolve the review thread."], environment: [:])
        #expect(report.command == .appControlRun(kind: .action, id: "coordinator.review.report", args: [
            "reviewID": .string(review), "intentID": .string(intent), "outcome": .string("blocked"), "detail": .string("Resolve the review thread."),
        ]))
        #expect(throws: ToasttyCLIError.self) {
            try ToasttyCLI.parse(arguments: ["coordinator", "review", "report", review, "--intent", intent, "--outcome", "approved", "--detail", "x"], environment: [:])
        }
    }

    @Test func mergeCarriesAnOptionalPersistedReviewIntent() throws {
        let intent = UUID().uuidString
        let head = String(repeating: "b", count: 40)
        let invocation = try ToasttyCLI.parse(arguments: ["task", "merge", "--head", head, "--review-intent", intent], environment: [:])
        #expect(invocation.command == .appControlRun(kind: .action, id: "task.merge", args: ["head": .string(head), "reviewIntentID": .string(intent)]))
        #expect(throws: ToasttyCLIError.self) {
            try ToasttyCLI.parse(arguments: ["task", "merge", "--review-intent", "invalid"], environment: [:])
        }
    }
}
