import Foundation

struct FuzzyMatch: Equatable, Sendable {
    let score: Int
}

enum FuzzyScorer {
    static func match(query: String, candidate: String) -> FuzzyMatch? {
        let normalizedQuery = query.normalizedPaletteQuery
        let normalizedCandidate = candidate.normalizedPaletteQuery

        guard normalizedQuery.isEmpty == false,
              normalizedCandidate.isEmpty == false,
              normalizedQuery.count <= normalizedCandidate.count else {
            return nil
        }

        let candidateCharacters = Array(normalizedCandidate)
        let queryCharacters = Array(normalizedQuery)
        var matchedPositions: [Int] = []
        var searchStartIndex = 0

        for queryCharacter in queryCharacters {
            guard let matchedIndex = candidateCharacters[searchStartIndex...].firstIndex(of: queryCharacter) else {
                return nil
            }
            matchedPositions.append(matchedIndex)
            searchStartIndex = matchedIndex + 1
        }

        guard matchedPositions.isEmpty == false else {
            return nil
        }

        var score = queryCharacters.count
        var contiguousRunLength = 1

        for (offset, position) in matchedPositions.enumerated() {
            if offset == 0 {
                if position == 0 {
                    score += 12
                }
                if isWordBoundary(at: position, in: candidateCharacters) {
                    score += 6
                }
                continue
            }

            let previousPosition = matchedPositions[offset - 1]
            let gap = position - previousPosition - 1
            if gap == 0 {
                contiguousRunLength += 1
                score += contiguousRunLength * 4
            } else {
                contiguousRunLength = 1
                score -= min(gap, 3)
                if isWordBoundary(at: position, in: candidateCharacters) {
                    score += 5
                }
            }
        }

        return FuzzyMatch(score: score)
    }

    private static func isWordBoundary(at index: Int, in characters: [Character]) -> Bool {
        guard characters.indices.contains(index) else {
            return false
        }
        if index == 0 {
            return true
        }
        let previous = characters[index - 1]
        return previous.isLetter == false && previous.isNumber == false
    }
}

extension String {
    var normalizedPaletteQuery: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
