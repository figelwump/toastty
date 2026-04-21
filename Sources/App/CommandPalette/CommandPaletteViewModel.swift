import Foundation
import SwiftUI

struct PaletteEmptyState: Equatable {
    let title: String
    let message: String
}

@MainActor
final class CommandPaletteViewModel: ObservableObject {
    private enum SelectionRefreshBehavior {
        case preserveCurrent
        case resetToTop
    }

    private struct ParsedPaletteQuery {
        let mode: PaletteMode
        let searchText: String
    }

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            refreshResults(selectionBehavior: .resetToTop)
        }
    }

    @Published private(set) var results: [PaletteResult] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var mode: PaletteMode = .commands
    @Published private(set) var placeholder = "Type a command..."
    @Published private(set) var footerText = "0 results"
    @Published private(set) var emptyState = PaletteEmptyState(
        title: "No matching commands",
        message: "Try a broader query."
    )

    let originWindowID: UUID
    let focusRequestID = UUID()

    private let projectCommands: @MainActor () -> [PaletteCommandDescriptor]
    private let executeCommand: @MainActor (PaletteCommandInvocation, UUID) -> Bool
    private let resolveFileSearchScope: @MainActor (UUID) -> PaletteFileSearchScope?
    private let openFileResult: @MainActor (PaletteFileOpenDestination, UUID) -> Bool
    private let loadFileResults: (PaletteFileSearchScope) async -> [PaletteFileResult]
    private let usageTracker: CommandPaletteUsageTracking
    private let onCancel: () -> Void
    private let onSubmitted: () -> Void

    private var refreshGeneration = 0
    private var fileRefreshTask: Task<Void, Never>?

    init(
        originWindowID: UUID,
        projectCommands: @escaping @MainActor () -> [PaletteCommandDescriptor],
        executeCommand: @escaping @MainActor (PaletteCommandInvocation, UUID) -> Bool,
        resolveFileSearchScope: @escaping @MainActor (UUID) -> PaletteFileSearchScope? = { _ in nil },
        openFileResult: @escaping @MainActor (PaletteFileOpenDestination, UUID) -> Bool = { _, _ in false },
        fileOpenProvider: CommandPaletteFileOpenProvider = CommandPaletteFileOpenProvider(),
        loadFileResults: ((PaletteFileSearchScope) async -> [PaletteFileResult])? = nil,
        usageTracker: CommandPaletteUsageTracking = NoOpCommandPaletteUsageTracker.shared,
        onCancel: @escaping () -> Void,
        onSubmitted: @escaping () -> Void
    ) {
        self.originWindowID = originWindowID
        self.projectCommands = projectCommands
        self.executeCommand = executeCommand
        self.resolveFileSearchScope = resolveFileSearchScope
        self.openFileResult = openFileResult
        if let loadFileResults {
            self.loadFileResults = loadFileResults
        } else {
            self.loadFileResults = { scope in
                await fileOpenProvider.indexedFiles(in: scope)
            }
        }
        self.usageTracker = usageTracker
        self.onCancel = onCancel
        self.onSubmitted = onSubmitted
        refreshResults(selectionBehavior: .preserveCurrent)
    }

    deinit {
        fileRefreshTask?.cancel()
    }

    var selectedResult: PaletteResult? {
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

        let didExecute: Bool
        switch result {
        case .command(let command):
            didExecute = executeCommand(command.command.invocation, originWindowID)
        case .file(let file):
            didExecute = openFileResult(file.destination, originWindowID)
        }

        if didExecute, let usageKey = result.usageKey {
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
        refreshGeneration += 1
        fileRefreshTask?.cancel()

        let parsedQuery = Self.parse(query: query)
        mode = parsedQuery.mode
        placeholder = parsedQuery.mode == .commands ? "Type a command..." : "Open a local file..."

        switch parsedQuery.mode {
        case .commands:
            refreshCommandResults(selectionBehavior: selectionBehavior, query: parsedQuery.searchText)
        case .fileOpen:
            refreshFileResults(selectionBehavior: selectionBehavior, searchText: parsedQuery.searchText)
        }
    }

    private func refreshCommandResults(
        selectionBehavior: SelectionRefreshBehavior,
        query: String
    ) {
        let normalizedQuery = query.normalizedPaletteQuery
        let previouslySelectedID = selectedResult?.id
        let commands = projectCommands()

        let matchedResults = commands.enumerated().compactMap { index, command -> RankedPaletteResult? in
            if normalizedQuery.isEmpty {
                return RankedPaletteResult(
                    result: .command(PaletteCommandResult(command: command)),
                    sourcePriority: 0,
                    matchScore: 0,
                    usageScore: 0,
                    catalogIndex: index
                )
            }

            guard let match = Self.match(title: command.title, keywords: command.keywords, query: normalizedQuery) else {
                return nil
            }

            return RankedPaletteResult(
                result: .command(PaletteCommandResult(command: command)),
                sourcePriority: match.source.priority,
                matchScore: match.score,
                usageScore: Self.usageScore(for: command.usageKey.map(usageTracker.useCount(for:))),
                catalogIndex: index
            )
        }

        if normalizedQuery.isEmpty {
            results = matchedResults.map(\.result)
        } else {
            results = matchedResults
                .sorted(by: Self.ranksHigher(_:_:))
                .map(\.result)
        }

        footerText = "\(results.count) results"
        emptyState = PaletteEmptyState(
            title: "No matching commands",
            message: "Try a broader query."
        )
        applySelectionBehavior(selectionBehavior, previouslySelectedID: previouslySelectedID)
    }

    private func refreshFileResults(
        selectionBehavior: SelectionRefreshBehavior,
        searchText: String
    ) {
        let generation = refreshGeneration
        let previouslySelectedID = selectedResult?.id

        guard let scope = resolveFileSearchScope(originWindowID) else {
            results = []
            footerText = "No contextual scope"
            emptyState = PaletteEmptyState(
                title: "No contextual file scope",
                message: "Focus a workspace terminal with a working directory, then try again."
            )
            applySelectionBehavior(selectionBehavior, previouslySelectedID: previouslySelectedID)
            return
        }

        results = []
        footerText = scope.label
        emptyState = PaletteEmptyState(
            title: "Scanning supported files",
            message: "Searching \(scope.displayPath)..."
        )
        applySelectionBehavior(selectionBehavior, previouslySelectedID: previouslySelectedID)

        let loadFileResults = self.loadFileResults
        fileRefreshTask = Task { [weak self] in
            let indexedFiles = await loadFileResults(scope)
            guard Task.isCancelled == false else { return }

            await MainActor.run {
                self?.applyFileResults(
                    indexedFiles,
                    scope: scope,
                    searchText: searchText,
                    selectionBehavior: selectionBehavior,
                    previouslySelectedID: previouslySelectedID,
                    generation: generation
                )
            }
        }
    }

    private func applyFileResults(
        _ files: [PaletteFileResult],
        scope: PaletteFileSearchScope,
        searchText: String,
        selectionBehavior: SelectionRefreshBehavior,
        previouslySelectedID: String?,
        generation: Int
    ) {
        guard generation == refreshGeneration else { return }

        let normalizedQuery = searchText.normalizedPaletteQuery
        if normalizedQuery.isEmpty {
            results = []
            emptyState = files.isEmpty
                ? PaletteEmptyState(
                    title: "No supported files in scope",
                    message: "No supported local-document or HTML files were found under \(scope.displayPath)."
                )
                : PaletteEmptyState(
                    title: "Type to search local files",
                    message: "Search supported local-document and HTML files under \(scope.displayPath)."
                )
            applySelectionBehavior(selectionBehavior, previouslySelectedID: previouslySelectedID)
            return
        }

        let matchedResults = files.enumerated().compactMap { index, file -> RankedPaletteResult? in
            guard let match = Self.match(
                title: file.fileName,
                keywords: [file.relativePath],
                query: normalizedQuery
            ) else {
                return nil
            }

            return RankedPaletteResult(
                result: .file(file),
                sourcePriority: match.source.priority,
                matchScore: match.score,
                usageScore: Self.usageScore(for: usageTracker.useCount(for: file.usageKey)),
                catalogIndex: index
            )
        }

        results = matchedResults
            .sorted(by: Self.ranksHigher(_:_:))
            .map(\.result)

        emptyState = results.isEmpty
            ? PaletteEmptyState(
                title: files.isEmpty ? "No supported files in scope" : "No matching files",
                message: files.isEmpty
                    ? "No supported local-document or HTML files were found under \(scope.displayPath)."
                    : "Try a broader file query inside \(scope.displayPath)."
            )
            : PaletteEmptyState(title: "", message: "")
        applySelectionBehavior(selectionBehavior, previouslySelectedID: previouslySelectedID)
    }

    private func applySelectionBehavior(
        _ behavior: SelectionRefreshBehavior,
        previouslySelectedID: String?
    ) {
        switch behavior {
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

    private static func parse(query: String) -> ParsedPaletteQuery {
        guard query.first == "@" else {
            return ParsedPaletteQuery(mode: .commands, searchText: query)
        }

        return ParsedPaletteQuery(
            mode: .fileOpen,
            searchText: String(query.dropFirst())
        )
    }

    private static func match(
        title: String,
        keywords: [String],
        query: String
    ) -> PaletteMatch? {
        if let titleMatch = FuzzyScorer.match(query: query, candidate: title) {
            return PaletteMatch(source: .title, score: titleMatch.score)
        }

        let keywordScore = keywords.compactMap { keyword in
            FuzzyScorer.match(query: query, candidate: keyword)?.score
        }.max()
        if let keywordScore {
            return PaletteMatch(source: .keyword, score: keywordScore)
        }

        return nil
    }

    private static func usageScore(for useCount: Int?) -> Double {
        log1p(Double(max(0, useCount ?? 0)))
    }

    private static func usageScore(for useCount: Int) -> Double {
        log1p(Double(max(0, useCount)))
    }

    private static func ranksHigher(_ lhs: RankedPaletteResult, _ rhs: RankedPaletteResult) -> Bool {
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

private struct RankedPaletteResult {
    let result: PaletteResult
    let sourcePriority: Int
    let matchScore: Int
    let usageScore: Double
    let catalogIndex: Int
}

private struct PaletteMatch {
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
