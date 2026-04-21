import Foundation

struct CommandPaletteFileUsageMetrics: Sendable {
    let useCount: Int
    let lastUsedAt: Date?
}

struct CommandPaletteFileSearchDocument: Sendable {
    let file: PaletteFileResult
    let normalizedFileName: String
    let normalizedRelativePath: String
    let usageScore: Double
    let lastUsedAt: Date?
    let pathDepth: Int
    let pathLength: Int
    let catalogIndex: Int
}

struct CommandPaletteFileSearchSnapshot: Sendable {
    let scope: PaletteFileSearchScope
    let documents: [CommandPaletteFileSearchDocument]

    static func empty(scope: PaletteFileSearchScope) -> CommandPaletteFileSearchSnapshot {
        CommandPaletteFileSearchSnapshot(scope: scope, documents: [])
    }
}

private struct RankedCommandPaletteFileResult {
    let file: PaletteFileResult
    let titleHitCount: Int
    let matchScore: Int
    let usageScore: Double
    let pathDepth: Int
    let pathLength: Int
    let catalogIndex: Int
}

private struct RecentCommandPaletteFileResult {
    let file: PaletteFileResult
    let lastUsedAt: Date
    let usageScore: Double
    let pathDepth: Int
    let pathLength: Int
    let catalogIndex: Int
}

private struct CommandPaletteFileTermMatch {
    enum Source {
        case title
        case path
    }

    let source: Source
    let score: Int
}

enum CommandPaletteFileSearchEngine {
    static func makeSnapshot(
        scope: PaletteFileSearchScope,
        files: [PaletteFileResult],
        usageMetrics: [String: CommandPaletteFileUsageMetrics]
    ) -> CommandPaletteFileSearchSnapshot {
        let documents = files.enumerated().map { index, file in
            let metrics = usageMetrics[file.usageKey] ?? CommandPaletteFileUsageMetrics(
                useCount: 0,
                lastUsedAt: nil
            )
            return CommandPaletteFileSearchDocument(
                file: file,
                normalizedFileName: file.fileName.normalizedPaletteQuery,
                normalizedRelativePath: file.relativePath.normalizedPaletteQuery,
                usageScore: usageScore(for: metrics.useCount),
                lastUsedAt: metrics.lastUsedAt,
                pathDepth: relativePathDepth(for: file.relativePath),
                pathLength: file.relativePath.count,
                catalogIndex: index
            )
        }

        return CommandPaletteFileSearchSnapshot(scope: scope, documents: documents)
    }

    static func recentResults(in snapshot: CommandPaletteFileSearchSnapshot) -> [PaletteResult] {
        snapshot.documents
            .compactMap { document in
                guard let lastUsedAt = document.lastUsedAt else {
                    return nil
                }

                return RecentCommandPaletteFileResult(
                    file: document.file,
                    lastUsedAt: lastUsedAt,
                    usageScore: document.usageScore,
                    pathDepth: document.pathDepth,
                    pathLength: document.pathLength,
                    catalogIndex: document.catalogIndex
                )
            }
            .sorted(by: recentFilesRankHigher(_:_:))
            .map { .file($0.file) }
    }

    static func search(snapshot: CommandPaletteFileSearchSnapshot, query: String) -> [PaletteResult] {
        let searchTerms = query.normalizedPaletteSearchTerms
        guard searchTerms.isEmpty == false else {
            return []
        }

        return snapshot.documents
            .compactMap { rankedMatch(for: $0, searchTerms: searchTerms) }
            .sorted(by: rankedFileResultsHigher(_:_:))
            .map { .file($0.file) }
    }

    private static func rankedMatch(
        for document: CommandPaletteFileSearchDocument,
        searchTerms: [String]
    ) -> RankedCommandPaletteFileResult? {
        var titleHitCount = 0
        var matchScore = 0

        for term in searchTerms {
            guard let bestMatch = bestMatch(for: document, term: term) else {
                return nil
            }

            matchScore += bestMatch.score
            if bestMatch.source == .title {
                titleHitCount += 1
            }
        }

        return RankedCommandPaletteFileResult(
            file: document.file,
            titleHitCount: titleHitCount,
            matchScore: matchScore,
            usageScore: document.usageScore,
            pathDepth: document.pathDepth,
            pathLength: document.pathLength,
            catalogIndex: document.catalogIndex
        )
    }

    private static func bestMatch(
        for document: CommandPaletteFileSearchDocument,
        term: String
    ) -> CommandPaletteFileTermMatch? {
        let titleMatch = FuzzyScorer.matchNormalized(
            query: term,
            candidate: document.normalizedFileName
        )
        let pathMatch = FuzzyScorer.matchNormalized(
            query: term,
            candidate: document.normalizedRelativePath
        )

        switch (titleMatch, pathMatch) {
        case (.none, .none):
            return nil
        case (.some(let match), .none):
            return CommandPaletteFileTermMatch(source: .title, score: match.score)
        case (.none, .some(let match)):
            return CommandPaletteFileTermMatch(source: .path, score: match.score)
        case (.some(let titleMatch), .some(let pathMatch)):
            if titleMatch.score != pathMatch.score {
                return titleMatch.score > pathMatch.score
                    ? CommandPaletteFileTermMatch(source: .title, score: titleMatch.score)
                    : CommandPaletteFileTermMatch(source: .path, score: pathMatch.score)
            }

            return CommandPaletteFileTermMatch(source: .title, score: titleMatch.score)
        }
    }

    private static func rankedFileResultsHigher(
        _ lhs: RankedCommandPaletteFileResult,
        _ rhs: RankedCommandPaletteFileResult
    ) -> Bool {
        if lhs.matchScore != rhs.matchScore {
            return lhs.matchScore > rhs.matchScore
        }
        if lhs.titleHitCount != rhs.titleHitCount {
            return lhs.titleHitCount > rhs.titleHitCount
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

    private static func recentFilesRankHigher(
        _ lhs: RecentCommandPaletteFileResult,
        _ rhs: RecentCommandPaletteFileResult
    ) -> Bool {
        if lhs.lastUsedAt != rhs.lastUsedAt {
            return lhs.lastUsedAt > rhs.lastUsedAt
        }
        if lhs.usageScore != rhs.usageScore {
            return lhs.usageScore > rhs.usageScore
        }
        if lhs.pathDepth != rhs.pathDepth {
            return lhs.pathDepth < rhs.pathDepth
        }
        if lhs.pathLength != rhs.pathLength {
            return lhs.pathLength < rhs.pathLength
        }
        return lhs.catalogIndex < rhs.catalogIndex
    }

    private static func relativePathDepth(for relativePath: String) -> Int {
        relativePath.split(separator: "/").count
    }

    private static func usageScore(for useCount: Int) -> Double {
        log1p(Double(max(0, useCount)))
    }
}
