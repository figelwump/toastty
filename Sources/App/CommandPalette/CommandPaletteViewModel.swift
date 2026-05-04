import Foundation
import SwiftUI

struct PaletteEmptyState: Equatable, Sendable {
    let title: String
    let message: String
}

struct FileResultsPresentation: Sendable {
    let results: [PaletteResult]
    let footerText: String
    let emptyState: PaletteEmptyState
}

private struct ActiveFileResultsState: Sendable {
    let scope: PaletteFileSearchScope
    var snapshot: CommandPaletteFileSearchSnapshot
    var isIndexing: Bool
    var hasLoadedSnapshot: Bool
}

@MainActor
final class CommandPaletteViewModel: ObservableObject {
    private enum SelectionRefreshBehavior: Sendable {
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
    private let openFileResult: @MainActor (PaletteFileOpenDestination, PaletteFileOpenPlacement, UUID) -> Bool
    private let fileIndexService: any CommandPaletteFileIndexing
    private let usageTracker: CommandPaletteUsageTracking
    private let filePresentationBuilder: @Sendable (
        CommandPaletteFileSearchSnapshot,
        String,
        Bool,
        Bool
    ) async -> FileResultsPresentation
    private let onCancel: () -> Void
    private let onSubmitted: () -> Void

    private var activeFileResultsState: ActiveFileResultsState?
    private var fileIndexTask: Task<Void, Never>?
    private var fileIndexScopePath: String?
    private var fileQueryTask: Task<Void, Never>?
    private var filePresentationGeneration = 0

    init(
        originWindowID: UUID,
        initialQuery: String = "",
        projectCommands: @escaping @MainActor () -> [PaletteCommandDescriptor],
        executeCommand: @escaping @MainActor (PaletteCommandInvocation, UUID) -> Bool,
        resolveFileSearchScope: @escaping @MainActor (UUID) -> PaletteFileSearchScope? = { _ in nil },
        openFileResult: @escaping @MainActor (PaletteFileOpenDestination, PaletteFileOpenPlacement, UUID) -> Bool = { _, _, _ in false },
        fileIndexService: any CommandPaletteFileIndexing = CommandPaletteFileOpenProvider(),
        usageTracker: CommandPaletteUsageTracking = NoOpCommandPaletteUsageTracker.shared,
        filePresentationBuilder: @escaping @Sendable (
            CommandPaletteFileSearchSnapshot,
            String,
            Bool,
            Bool
        ) async -> FileResultsPresentation = CommandPaletteViewModel.buildFileResultsPresentationOffMain,
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
        self.filePresentationBuilder = filePresentationBuilder
        self.onCancel = onCancel
        self.onSubmitted = onSubmitted
        query = initialQuery
        refreshResults(selectionBehavior: .preserveCurrent)
    }

    deinit {
        fileIndexTask?.cancel()
        fileQueryTask?.cancel()
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
        submit(placement: .default)
    }

    func submitAlternateSelection() {
        submit(placement: .alternate)
    }

    private func submit(placement: PaletteFileOpenPlacement) {
        guard let result = selectedResult else { return }

        let didExecute: Bool
        switch result {
        case .command(let command):
            didExecute = executeCommand(command.command.invocation, originWindowID)
        case .file(let file):
            didExecute = openFileResult(file.destination, placement, originWindowID)
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
        let parsedQuery = Self.parse(query: query)
        mode = parsedQuery.mode
        placeholder = parsedQuery.mode == .commands ? "Type a command..." : "Open a local file..."

        switch parsedQuery.mode {
        case .commands:
            fileQueryTask?.cancel()
            refreshCommandResults(selectionBehavior: selectionBehavior, query: parsedQuery.searchText)
        case .fileOpen:
            refreshFileResults(selectionBehavior: selectionBehavior)
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

        // footerText is unused in commands mode; the view shows a static "@" hint.
        footerText = ""
        emptyState = PaletteEmptyState(
            title: "No matching commands",
            message: "Try a broader query."
        )
        applySelectionBehavior(selectionBehavior, previouslySelectedID: previouslySelectedID)
    }

    private func refreshFileResults(selectionBehavior: SelectionRefreshBehavior) {
        let previouslySelectedID = selectedResult?.id

        guard let scope = resolveFileSearchScope(originWindowID) else {
            fileQueryTask?.cancel()
            results = []
            footerText = "No contextual scope"
            emptyState = PaletteEmptyState(
                title: "No contextual file scope",
                message: "Focus a workspace terminal with a working directory, then try again."
            )
            applySelectionBehavior(selectionBehavior, previouslySelectedID: previouslySelectedID)
            return
        }

        ensureActiveFileResultsState(for: scope)
        maybeStartFileIndexLoad(for: scope)
        scheduleFilePresentation(
            for: scope,
            selectionBehavior: selectionBehavior,
            previouslySelectedID: previouslySelectedID
        )
    }

    private func ensureActiveFileResultsState(for scope: PaletteFileSearchScope) {
        guard activeFileResultsState?.scope != scope else { return }
        activeFileResultsState = ActiveFileResultsState(
            scope: scope,
            snapshot: .empty(scope: scope),
            isIndexing: false,
            hasLoadedSnapshot: false
        )
    }

    private func maybeStartFileIndexLoad(for scope: PaletteFileSearchScope) {
        guard let activeFileResultsState,
              activeFileResultsState.scope == scope,
              activeFileResultsState.hasLoadedSnapshot == false else {
            return
        }

        if fileIndexScopePath == scope.rootPath {
            return
        }

        if let fileIndexScopePath,
           fileIndexScopePath != scope.rootPath {
            fileIndexTask?.cancel()
        }

        self.fileIndexScopePath = scope.rootPath
        self.activeFileResultsState?.isIndexing = true

        let fileIndexService = self.fileIndexService
        fileIndexTask = Task { [weak self] in
            let snapshot = await fileIndexService.prepareIndex(in: scope)
            guard Task.isCancelled == false else { return }

            let cachedUsageMetrics = await MainActor.run { [weak self] in
                self?.fileUsageMetrics(for: snapshot.results) ?? [:]
            }

            await MainActor.run { [weak self] in
                self?.applyFileIndexUpdate(
                    files: snapshot.results,
                    usageMetrics: cachedUsageMetrics,
                    isIndexing: snapshot.isIndexing,
                    hasLoadedSnapshot: true,
                    for: scope
                )
            }

            guard snapshot.isIndexing else {
                await MainActor.run { [weak self] in
                    self?.finishFileIndexLoad(for: scope)
                }
                return
            }

            let indexedFiles = await fileIndexService.indexedFiles(in: scope)
            guard Task.isCancelled == false else { return }

            let refreshedUsageMetrics = await MainActor.run { [weak self] in
                self?.fileUsageMetrics(for: indexedFiles) ?? [:]
            }

            await MainActor.run { [weak self] in
                self?.applyFileIndexUpdate(
                    files: indexedFiles,
                    usageMetrics: refreshedUsageMetrics,
                    isIndexing: false,
                    hasLoadedSnapshot: true,
                    for: scope
                )
                self?.finishFileIndexLoad(for: scope)
            }
        }
    }

    private func applyFileIndexUpdate(
        files: [PaletteFileResult],
        usageMetrics: [String: CommandPaletteFileUsageMetrics],
        isIndexing: Bool,
        hasLoadedSnapshot: Bool,
        for scope: PaletteFileSearchScope
    ) {
        guard var state = activeFileResultsState,
              state.scope == scope else {
            return
        }

        state.snapshot = CommandPaletteFileSearchEngine.makeSnapshot(
            scope: scope,
            files: files,
            usageMetrics: usageMetrics
        )
        state.isIndexing = isIndexing
        state.hasLoadedSnapshot = hasLoadedSnapshot
        activeFileResultsState = state

        guard mode == .fileOpen,
              resolveFileSearchScope(originWindowID) == scope else {
            return
        }

        scheduleFilePresentation(
            for: scope,
            selectionBehavior: .preserveCurrent,
            previouslySelectedID: selectedResult?.id
        )
    }

    private func finishFileIndexLoad(for scope: PaletteFileSearchScope) {
        guard fileIndexScopePath == scope.rootPath else { return }
        fileIndexTask = nil
        fileIndexScopePath = nil
    }

    private func scheduleFilePresentation(
        for scope: PaletteFileSearchScope,
        selectionBehavior: SelectionRefreshBehavior,
        previouslySelectedID: String?
    ) {
        guard let state = activeFileResultsState,
              state.scope == scope else {
            return
        }

        let searchText = Self.parse(query: query).searchText
        let snapshot = state.snapshot
        let isIndexing = state.isIndexing
        let hasLoadedSnapshot = state.hasLoadedSnapshot
        let filePresentationBuilder = self.filePresentationBuilder
        filePresentationGeneration += 1
        let generation = filePresentationGeneration

        fileQueryTask?.cancel()
        // Search work runs from an immutable snapshot. Only the latest generation for the
        // still-active scope may publish back into the palette state.
        fileQueryTask = Task { [weak self] in
            let presentation = await filePresentationBuilder(
                snapshot,
                searchText,
                isIndexing,
                hasLoadedSnapshot
            )
            guard Task.isCancelled == false else { return }
            self?.applyFilePresentation(
                presentation,
                selectionBehavior: selectionBehavior,
                previouslySelectedID: previouslySelectedID,
                generation: generation,
                expectedScope: scope
            )
        }
    }

    private func applyFilePresentation(
        _ presentation: FileResultsPresentation,
        selectionBehavior: SelectionRefreshBehavior,
        previouslySelectedID: String?,
        generation: Int,
        expectedScope: PaletteFileSearchScope
    ) {
        guard generation == filePresentationGeneration,
              mode == .fileOpen,
              resolveFileSearchScope(originWindowID) == expectedScope else {
            return
        }

        results = presentation.results
        footerText = presentation.footerText
        emptyState = presentation.emptyState
        applySelectionBehavior(selectionBehavior, previouslySelectedID: previouslySelectedID)
    }

    private func fileUsageMetrics(for files: [PaletteFileResult]) -> [String: CommandPaletteFileUsageMetrics] {
        var usageMetrics: [String: CommandPaletteFileUsageMetrics] = [:]
        usageMetrics.reserveCapacity(files.count)

        for file in files {
            usageMetrics[file.usageKey] = CommandPaletteFileUsageMetrics(
                useCount: usageTracker.useCount(for: file.usageKey),
                lastUsedAt: usageTracker.lastUsedAt(for: file.usageKey)
            )
        }

        return usageMetrics
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
            title: "Indexing local files",
            message: scope.label
        )
    }

    nonisolated private static func emptySearchPrompt(for scope: PaletteFileSearchScope) -> PaletteEmptyState {
        PaletteEmptyState(
            title: "Type to search local files",
            message: scope.label
        )
    }

    nonisolated private static func noSupportedFilesState(for scope: PaletteFileSearchScope) -> PaletteEmptyState {
        PaletteEmptyState(
            title: "No supported files in scope",
            message: scope.label
        )
    }

    nonisolated private static func noMatchingFilesState(for scope: PaletteFileSearchScope) -> PaletteEmptyState {
        PaletteEmptyState(
            title: "No matching files",
            message: "Try a broader file query inside \(scope.displayPath)."
        )
    }

    nonisolated static func buildFileResultsPresentationOffMain(
        snapshot: CommandPaletteFileSearchSnapshot,
        searchText: String,
        isIndexing: Bool,
        hasLoadedSnapshot: Bool
    ) async -> FileResultsPresentation {
        let task = Task.detached(priority: .userInitiated) {
            Self.makeFileResultsPresentation(
                snapshot: snapshot,
                searchText: searchText,
                isIndexing: isIndexing,
                hasLoadedSnapshot: hasLoadedSnapshot
            )
        }

        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func makeFileResultsPresentation(
        snapshot: CommandPaletteFileSearchSnapshot,
        searchText: String,
        isIndexing: Bool,
        hasLoadedSnapshot: Bool
    ) -> FileResultsPresentation {
        let searchTerms = searchText.normalizedPaletteSearchTerms

        if searchTerms.isEmpty {
            let recentResults = CommandPaletteFileSearchEngine.recentResults(in: snapshot)
            if recentResults.isEmpty == false {
                return FileResultsPresentation(
                    results: recentResults,
                    footerText: snapshot.scope.label,
                    emptyState: PaletteEmptyState(title: "", message: "")
                )
            }

            return FileResultsPresentation(
                results: [],
                footerText: snapshot.scope.label,
                emptyState: emptySearchPrompt(for: snapshot.scope)
            )
        }

        if isIndexing && snapshot.documents.isEmpty {
            return FileResultsPresentation(
                results: [],
                footerText: snapshot.scope.label,
                emptyState: indexingEmptyState(for: snapshot.scope)
            )
        }

        let results = CommandPaletteFileSearchEngine.search(snapshot: snapshot, query: searchText)
        let emptyState = results.isEmpty
            ? (
                snapshot.documents.isEmpty && hasLoadedSnapshot
                    ? noSupportedFilesState(for: snapshot.scope)
                    : noMatchingFilesState(for: snapshot.scope)
            )
            : PaletteEmptyState(title: "", message: "")

        return FileResultsPresentation(
            results: results,
            footerText: snapshot.scope.label,
            emptyState: emptyState
        )
    }

    nonisolated private static func usageScore(for useCount: Int?) -> Double {
        log1p(Double(max(0, useCount ?? 0)))
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
