import Foundation
import SwiftUI

@MainActor
final class CommandPaletteViewModel: ObservableObject {
    private enum SelectionRefreshBehavior {
        case preserveCurrent
        case resetToTop
    }

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            refreshResults(selectionBehavior: .resetToTop)
        }
    }

    @Published private(set) var results: [PaletteCommandResult] = []
    @Published private(set) var selectedIndex = 0

    let originWindowID: UUID
    let focusRequestID = UUID()

    private let projectCommands: @MainActor () -> [PaletteCommandDescriptor]
    private let executeCommand: @MainActor (PaletteCommandInvocation, UUID) -> Bool
    private let usageTracker: CommandPaletteUsageTracking
    private let onCancel: () -> Void
    private let onSubmitted: () -> Void

    init(
        originWindowID: UUID,
        projectCommands: @escaping @MainActor () -> [PaletteCommandDescriptor],
        executeCommand: @escaping @MainActor (PaletteCommandInvocation, UUID) -> Bool,
        usageTracker: CommandPaletteUsageTracking = NoOpCommandPaletteUsageTracker.shared,
        onCancel: @escaping () -> Void,
        onSubmitted: @escaping () -> Void
    ) {
        self.originWindowID = originWindowID
        self.projectCommands = projectCommands
        self.executeCommand = executeCommand
        self.usageTracker = usageTracker
        self.onCancel = onCancel
        self.onSubmitted = onSubmitted
        refreshResults(selectionBehavior: .preserveCurrent)
    }

    var selectedResult: PaletteCommandResult? {
        guard results.indices.contains(selectedIndex) else {
            return nil
        }
        return results[selectedIndex]
    }

    func moveSelection(delta: Int) {
        guard results.isEmpty == false else { return }
        let lastIndex = results.count - 1
        selectedIndex = max(0, min(lastIndex, selectedIndex + delta))
    }

    func select(index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    func submitSelection() {
        guard let result = selectedResult else { return }
        // Dismiss after any explicit submission so no-op commands do not leave
        // the palette looking stuck when the underlying action returns false.
        let didExecute = executeCommand(result.command.invocation, originWindowID)
        if didExecute, let usageKey = result.command.usageKey {
            usageTracker.recordSuccessfulExecution(of: usageKey)
        }
        onSubmitted()
    }

    func dismiss() {
        onCancel()
    }

    func refreshProjectedCommands() {
        refreshResults(selectionBehavior: .preserveCurrent)
    }

    private func refreshResults(selectionBehavior: SelectionRefreshBehavior) {
        let normalizedQuery = query.normalizedPaletteQuery
        let previouslySelectedID = selectedResult?.id
        let commands = projectCommands()

        let matchedResults = commands.enumerated().compactMap { index, command -> RankedPaletteCommandResult? in
            if normalizedQuery.isEmpty {
                return RankedPaletteCommandResult(
                    result: PaletteCommandResult(command: command),
                    sourcePriority: 0,
                    matchScore: 0,
                    usageScore: 0,
                    catalogIndex: index
                )
            }

            guard let match = Self.match(command: command, query: normalizedQuery) else {
                return nil
            }

            return RankedPaletteCommandResult(
                result: PaletteCommandResult(command: command),
                sourcePriority: match.source.priority,
                matchScore: match.score,
                usageScore: Self.usageScore(
                    for: command.usageKey.map(usageTracker.useCount(for:))
                ),
                catalogIndex: index
            )
        }

        if normalizedQuery.isEmpty {
            results = matchedResults.map { $0.result }
        } else {
            results = matchedResults
                .sorted(by: Self.ranksHigher(_:_:))
                .map { $0.result }
        }

        switch selectionBehavior {
        case .preserveCurrent:
            if let previouslySelectedID,
               let preservedIndex = results.firstIndex(where: { $0.id == previouslySelectedID }) {
                selectedIndex = preservedIndex
                return
            }

            selectedIndex = results.isEmpty ? 0 : min(selectedIndex, results.count - 1)
        case .resetToTop:
            selectedIndex = 0
        }
    }

    private static func match(
        command: PaletteCommandDescriptor,
        query: String
    ) -> PaletteCommandMatch? {
        if let titleMatch = FuzzyScorer.match(query: query, candidate: command.title) {
            return PaletteCommandMatch(source: .title, score: titleMatch.score)
        }

        let keywordScore = command.keywords.compactMap { keyword in
            FuzzyScorer.match(query: query, candidate: keyword)?.score
        }.max()
        if let keywordScore {
            return PaletteCommandMatch(source: .keyword, score: keywordScore)
        }

        return nil
    }

    private static func usageScore(for useCount: Int?) -> Double {
        log1p(Double(max(0, useCount ?? 0)))
    }

    private static func ranksHigher(_ lhs: RankedPaletteCommandResult, _ rhs: RankedPaletteCommandResult) -> Bool {
        if lhs.sourcePriority != rhs.sourcePriority {
            return lhs.sourcePriority > rhs.sourcePriority
        }
        if lhs.matchScore != rhs.matchScore {
            return lhs.matchScore > rhs.matchScore
        }
        if lhs.usageScore != rhs.usageScore {
            return lhs.usageScore > rhs.usageScore
        }
        return lhs.catalogIndex < rhs.catalogIndex
    }
}

private struct RankedPaletteCommandResult {
    let result: PaletteCommandResult
    let sourcePriority: Int
    let matchScore: Int
    let usageScore: Double
    let catalogIndex: Int
}

private struct PaletteCommandMatch {
    enum Source {
        case title
        case keyword

        var priority: Int {
            switch self {
            case .title:
                return 1
            case .keyword:
                return 0
            }
        }
    }

    let source: Source
    let score: Int
}
