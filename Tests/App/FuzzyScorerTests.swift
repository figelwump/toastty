import XCTest
@testable import ToasttyApp

final class FuzzyScorerTests: XCTestCase {
    func testReturnsNilWhenQueryCharactersAreMissing() {
        XCTAssertNil(FuzzyScorer.match(query: "zzz", candidate: "Split Down"))
    }

    func testMatchesNonContiguousCharactersAcrossWords() throws {
        let match = try XCTUnwrap(FuzzyScorer.match(query: "spdn", candidate: "Split Down"))

        XCTAssertGreaterThan(match.score, 0)
    }

    func testPrefersPrefixContiguousMatchOverGappyMatch() throws {
        let prefixMatch = try XCTUnwrap(FuzzyScorer.match(query: "spl", candidate: "Split Down"))
        let gappyMatch = try XCTUnwrap(FuzzyScorer.match(query: "spd", candidate: "Split Down"))

        XCTAssertGreaterThan(prefixMatch.score, gappyMatch.score)
    }

    func testWordBoundaryMatchOutranksDeepInternalMatch() throws {
        let boundaryMatch = try XCTUnwrap(FuzzyScorer.match(query: "dn", candidate: "Split Down"))
        let internalMatch = try XCTUnwrap(FuzzyScorer.match(query: "dn", candidate: "Sidebar Navigation"))

        XCTAssertGreaterThan(boundaryMatch.score, internalMatch.score)
    }
}
