import Foundation
import SwiftUI

@MainActor
final class CommandPaletteViewModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            refreshResults()
        }
    }

    @Published private(set) var results: [PaletteCommandResult] = []
    @Published private(set) var selectedIndex = 0

    let originWindowID: UUID
    let focusRequestID = UUID()

    private let commands: [PaletteCommand]
    private let actions: CommandPaletteActionHandling
    private let usageTracker: CommandPaletteUsageTracking
    private let onCancel: () -> Void
    private let onSubmitted: () -> Void

    init(
        originWindowID: UUID,
        commands: [PaletteCommand],
        actions: CommandPaletteActionHandling,
        usageTracker: CommandPaletteUsageTracking = NoOpCommandPaletteUsageTracker.shared,
        onCancel: @escaping () -> Void,
        onSubmitted: @escaping () -> Void
    ) {
        self.originWindowID = originWindowID
        self.commands = commands
        self.actions = actions
        self.usageTracker = usageTracker
        self.onCancel = onCancel
        self.onSubmitted = onSubmitted
        refreshResults()
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
        let context = CommandExecutionContext(originWindowID: originWindowID, actions: actions)
        // Dismiss after any explicit submission so no-op commands do not leave
        // the palette looking stuck when the underlying action returns false.
        let didExecute = result.command.execute(context)
        if didExecute {
            usageTracker.recordSuccessfulExecution(of: result.command.id)
        }
        onSubmitted()
    }

    func dismiss() {
        onCancel()
    }

    private func refreshResults() {
        let context = CommandExecutionContext(originWindowID: originWindowID, actions: actions)
        let normalizedQuery = query.normalizedPaletteQuery
        let previouslySelectedID = selectedResult?.id

        let matchedResults = commands.enumerated().compactMap { index, command -> RankedPaletteCommandResult? in
            guard command.isAvailable(context) else {
                return nil
            }

            let title = command.title(context)
            if normalizedQuery.isEmpty {
                return RankedPaletteCommandResult(
                    result: PaletteCommandResult(command: command, title: title),
                    sourcePriority: 0,
                    matchPriority: 0,
                    usageScore: 0,
                    catalogIndex: index
                )
            }

            guard let match = Self.match(command: command, title: title, query: normalizedQuery) else {
                return nil
            }

            return RankedPaletteCommandResult(
                result: PaletteCommandResult(command: command, title: title),
                sourcePriority: match.source.priority,
                matchPriority: match.kind.priority,
                usageScore: Self.usageScore(for: usageTracker.useCount(for: command.id)),
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

        if let previouslySelectedID,
           let preservedIndex = results.firstIndex(where: { $0.id == previouslySelectedID }) {
            selectedIndex = preservedIndex
            return
        }

        selectedIndex = results.isEmpty ? 0 : min(selectedIndex, results.count - 1)
    }

    private static func match(
        command: PaletteCommand,
        title: String,
        query: String
    ) -> PaletteCommandMatch? {
        if let titleKind = matchKind(candidate: title.normalizedPaletteQuery, query: query) {
            return PaletteCommandMatch(source: .title, kind: titleKind)
        }

        let keywordKind = command.keywords.compactMap { keyword in
            matchKind(candidate: keyword.normalizedPaletteQuery, query: query)
        }.max(by: { $0.priority < $1.priority })
        if let keywordKind {
            return PaletteCommandMatch(source: .keyword, kind: keywordKind)
        }

        return nil
    }

    private static func matchKind(candidate: String, query: String) -> PaletteCommandMatch.Kind? {
        guard let range = candidate.range(of: query) else {
            return nil
        }

        if range.lowerBound == candidate.startIndex {
            return .prefix
        }

        let previousCharacter = candidate[candidate.index(before: range.lowerBound)]
        if previousCharacter.isLetter || previousCharacter.isNumber {
            return .substring
        }
        return .wordBoundarySubstring
    }

    private static func usageScore(for useCount: Int) -> Double {
        log1p(Double(max(0, useCount)))
    }

    private static func ranksHigher(_ lhs: RankedPaletteCommandResult, _ rhs: RankedPaletteCommandResult) -> Bool {
        if lhs.sourcePriority != rhs.sourcePriority {
            return lhs.sourcePriority > rhs.sourcePriority
        }
        if lhs.matchPriority != rhs.matchPriority {
            return lhs.matchPriority > rhs.matchPriority
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
    let matchPriority: Int
    let usageScore: Double
    let catalogIndex: Int
}

private struct PaletteCommandMatch {
    enum Kind {
        case prefix
        case wordBoundarySubstring
        case substring

        var priority: Int {
            switch self {
            case .prefix:
                return 2
            case .wordBoundarySubstring:
                return 1
            case .substring:
                return 0
            }
        }
    }

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
    let kind: Kind
}

private extension String {
    var normalizedPaletteQuery: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
