import Foundation
import SwiftUI

struct PaletteEmptyState: Equatable, Sendable {
    let title: String
    let message: String
}

private struct FileResultsPresentation: Sendable {
    let results: [PaletteResult]
    let footerText: String
    let emptyState: PaletteEmptyState
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

    nonisolated private static let supportedFileExtensionList = CommandPaletteFileOpenRouting
        .supportedPathExtensions
        .sorted()
        .map { ".\($0)" }
        .joined(separator: ", ")

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
    private let fileIndexService: any CommandPaletteFileIndexing
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
        fileIndexService: any CommandPaletteFileIndexing = CommandPaletteFileOpenProvider(),
        usageTracker: CommandPaletteUsageTracking = NoOpCommandPaletteUsageTracker.shared,
        onCancel: @escaping () -> Void,
        onSubmitted: @escaping () -> Void
    ) {
        self.originWindowID = originWindowID
        self.projectCommands = projectCommands
        self.executeCommand = executeCommand
        self.resolveFileSearchScope = resolveFileSearchScope
        self.openFileResult = openFileResult
        self.fileIndexService = fileIndexService
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
        emptyState = Self.indexingEmptyState(for: scope)
        applySelectionBehavior(selectionBehavior, previouslySelectedID: previouslySelectedID)

        let fileIndexService = self.fileIndexService
        fileRefreshTask = Task { [weak self] in
            let snapshot = await fileIndexService.prepareIndex(in: scope)
            guard Task.isCancelled == false else { return }

            let cachedUsageCounts = await MainActor.run { [weak self] in
                self?.fileUsageCounts(for: snapshot.results) ?? [:]
            }
            let cachedPresentation = Self.makeFileResultsPresentation(
                files: snapshot.results,
                scope: scope,
                searchText: searchText,
                isIndexing: snapshot.isIndexing,
                usageCounts: cachedUsageCounts
            )

            await MainActor.run { [weak self] in
                self?.applyFilePresentation(
                    cachedPresentation,
                    selectionBehavior: selectionBehavior,
                    previouslySelectedID: previouslySelectedID,
                    generation: generation
                )
            }

            guard snapshot.isIndexing else { return }

            let indexedFiles = await fileIndexService.indexedFiles(in: scope)
            guard Task.isCancelled == false else { return }

            let refreshedUsageCounts = await MainActor.run { [weak self] in
                self?.fileUsageCounts(for: indexedFiles) ?? [:]
            }
            let refreshedPresentation = Self.makeFileResultsPresentation(
                files: indexedFiles,
                scope: scope,
                searchText: searchText,
                isIndexing: false,
                usageCounts: refreshedUsageCounts
            )

            await MainActor.run { [weak self] in
                self?.applyFilePresentation(
                    refreshedPresentation,
                    selectionBehavior: selectionBehavior,
                    previouslySelectedID: previouslySelectedID,
                    generation: generation
                )
            }
        }
    }

    private func applyFilePresentation(
        _ presentation: FileResultsPresentation,
        selectionBehavior: SelectionRefreshBehavior,
        previouslySelectedID: String?,
        generation: Int
    ) {
        guard generation == refreshGeneration else { return }

        results = presentation.results
        footerText = presentation.footerText
        emptyState = presentation.emptyState
        applySelectionBehavior(selectionBehavior, previouslySelectedID: previouslySelectedID)
    }

    private func fileUsageCounts(for files: [PaletteFileResult]) -> [String: Int] {
        var usageCounts: [String: Int] = [:]
        usageCounts.reserveCapacity(files.count)

        for file in files {
            usageCounts[file.usageKey] = usageTracker.useCount(for: file.usageKey)
        }

        return usageCounts
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

    nonisolated private static func match(
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

    nonisolated private static func indexingEmptyState(for scope: PaletteFileSearchScope) -> PaletteEmptyState {
        PaletteEmptyState(
            title: "Indexing supported files",
            message: "Searching \(scope.displayPath) for \(supportedFileExtensionList)."
        )
    }

    nonisolated private static func emptySearchPrompt(for scope: PaletteFileSearchScope) -> PaletteEmptyState {
        PaletteEmptyState(
            title: "Type to search local files",
            message: "Supported extensions: \(supportedFileExtensionList). Search under \(scope.displayPath)."
        )
    }

    nonisolated private static func noSupportedFilesState(for scope: PaletteFileSearchScope) -> PaletteEmptyState {
        PaletteEmptyState(
            title: "No supported files in scope",
            message: "No files with supported extensions were found under \(scope.displayPath). Supported extensions: \(supportedFileExtensionList)."
        )
    }

    nonisolated private static func noMatchingFilesState(for scope: PaletteFileSearchScope) -> PaletteEmptyState {
        PaletteEmptyState(
            title: "No matching files",
            message: "Try a broader file query inside \(scope.displayPath)."
        )
    }

    nonisolated private static func makeFileResultsPresentation(
        files: [PaletteFileResult],
        scope: PaletteFileSearchScope,
        searchText: String,
        isIndexing: Bool,
        usageCounts: [String: Int]
    ) -> FileResultsPresentation {
        let normalizedQuery = searchText.normalizedPaletteQuery

        if normalizedQuery.isEmpty {
            let emptyState: PaletteEmptyState
            if isIndexing && files.isEmpty {
                emptyState = indexingEmptyState(for: scope)
            } else if files.isEmpty {
                emptyState = noSupportedFilesState(for: scope)
            } else {
                emptyState = emptySearchPrompt(for: scope)
            }

            return FileResultsPresentation(
                results: [],
                footerText: scope.label,
                emptyState: emptyState
            )
        }

        if isIndexing && files.isEmpty {
            return FileResultsPresentation(
                results: [],
                footerText: scope.label,
                emptyState: indexingEmptyState(for: scope)
            )
        }

        let matchedResults = files.enumerated().compactMap { index, file -> RankedPaletteResult? in
            guard let match = match(
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
                usageScore: usageScore(for: usageCounts[file.usageKey]),
                pathDepth: relativePathDepth(for: file.relativePath),
                pathLength: file.relativePath.count,
                catalogIndex: index
            )
        }

        let results = matchedResults
            .sorted(by: ranksHigher(_:_:))
            .map(\.result)
        let emptyState = results.isEmpty
            ? (files.isEmpty ? noSupportedFilesState(for: scope) : noMatchingFilesState(for: scope))
            : PaletteEmptyState(title: "", message: "")

        return FileResultsPresentation(
            results: results,
            footerText: scope.label,
            emptyState: emptyState
        )
    }

    nonisolated private static func relativePathDepth(for relativePath: String) -> Int {
        relativePath.split(separator: "/").count
    }

    nonisolated private static func usageScore(for useCount: Int?) -> Double {
        log1p(Double(max(0, useCount ?? 0)))
    }

    nonisolated private static func usageScore(for useCount: Int) -> Double {
        log1p(Double(max(0, useCount)))
    }

    nonisolated private static func ranksHigher(_ lhs: RankedPaletteResult, _ rhs: RankedPaletteResult) -> Bool {
        if lhs.sourcePriority != rhs.sourcePriority {
            return lhs.sourcePriority > rhs.sourcePriority
        }
        if lhs.matchScore != rhs.matchScore {
            return lhs.matchScore > rhs.matchScore
        }
        if lhs.pathDepth != rhs.pathDepth {
            return lhs.pathDepth < rhs.pathDepth
        }
        if lhs.pathLength != rhs.pathLength {
            return lhs.pathLength < rhs.pathLength
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
    let pathDepth: Int
    let pathLength: Int
    let catalogIndex: Int

    init(
        result: PaletteResult,
        sourcePriority: Int,
        matchScore: Int,
        usageScore: Double,
        pathDepth: Int = .max,
        pathLength: Int = .max,
        catalogIndex: Int
    ) {
        self.result = result
        self.sourcePriority = sourcePriority
        self.matchScore = matchScore
        self.usageScore = usageScore
        self.pathDepth = pathDepth
        self.pathLength = pathLength
        self.catalogIndex = catalogIndex
    }
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
