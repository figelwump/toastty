import CoreState
import SwiftUI

/// Updates the sidebar from review decisions even while the home is closed.
struct CoordinatorDecisionBadge<Content: View>: View {
    @ObservedObject var reviews: CoordinatorReviewStore
    @ObservedObject var board: TaskBoardStore
    @ViewBuilder let content: (Int) -> Content

    var body: some View {
        let tasks = board.items()
        let entries = CoordinatorReviewPresentation.queue(native: reviews.queue, saved: reviews.items)
        let count = entries.filter { entry in
            guard let review = CoordinatorReviewPresentation.displayedReview(entry, saved: reviews.items) else { return true }
            return CoordinatorReviewPresentation.state(review, task: tasks.first { $0.taskID == entry.taskID }).needsAttention
        }.count
        content(count)
    }
}
