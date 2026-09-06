import Foundation
import XCTest
@testable import ToasttyMobileApp

final class ToasttyMarkdownChunkingTests: XCTestCase {
    func testShortTextKeepsOneSemanticChunk() {
        let text = "A **short** message with `code`."
        let chunks = ToasttyMarkdownChunking.split(text)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].blocks, ToasttyMarkdownParser.parse(text))
    }

    func testLongParagraphsPreserveAllParsedContentWithinBoundedChunks() {
        let text = (1...14).map { index in
            "Paragraph \(index): " + String(repeating: "chunked body ", count: 80)
        }.joined(separator: "\n\n")
        let chunks = ToasttyMarkdownChunking.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(renderedText(chunks), parsedText(text))
        XCTAssertTrue(chunks.allSatisfy { $0.blocks.reduce(0) { $0 + $1.content.characters.count } <= 2_000 })
    }

    func testFenceAfterProseWithoutBlankLinePreservesCodeInEveryChunk() {
        let text = "Introduction\n```swift\n"
            + (1...160).map { "let value\($0) = functionWithLongName(\($0))" }.joined(separator: "\n")
            + "\n```"
        let chunks = ToasttyMarkdownChunking.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(renderedText(chunks), parsedText(text))
        let blocks = chunks.flatMap(\.blocks)
        XCTAssertEqual(blocks.first?.style, .paragraph)
        XCTAssertTrue(blocks.dropFirst().allSatisfy { $0.style == .code(language: "swift") })
    }

    func testReferenceLinksResolveBeforeLayoutSplitting() {
        let text = "See [the docs][reference].\n\n"
            + String(repeating: "A paragraph of padding.\n\n", count: 200)
            + "[reference]: https://example.com/docs"
        let chunks = ToasttyMarkdownChunking.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        let links = chunks.flatMap(\.blocks).flatMap { block in
            block.content.runs.compactMap(\.link)
        }
        XCTAssertEqual(links, [URL(string: "https://example.com/docs")!])
        XCTAssertEqual(renderedText(chunks), parsedText(text))
    }

    func testHugeCodeLineIsBoundedWithoutLosingCharactersOrCodeStyle() {
        let text = "```json\n" + String(repeating: "a", count: 20_000) + "\n```"
        let chunks = ToasttyMarkdownChunking.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(renderedText(chunks), parsedText(text))
        for block in chunks.flatMap(\.blocks) {
            XCTAssertEqual(block.style, .code(language: "json"))
            XCTAssertLessThanOrEqual(block.content.characters.count, 2_000)
        }
    }

    func testSplitListItemKeepsStyleAndMarksContinuationWithoutRepeatedBullet() {
        let text = "1. " + String(repeating: "word ", count: 900)
        let blocks = ToasttyMarkdownChunking.split(text).flatMap(\.blocks)
        XCTAssertGreaterThan(blocks.count, 1)
        XCTAssertEqual(blocks.first?.isContinuation, false)
        XCTAssertTrue(blocks.dropFirst().allSatisfy(\.isContinuation))
        XCTAssertTrue(blocks.allSatisfy { $0.style == .list(marker: .ordered(1), depth: 1) })
        XCTAssertEqual(blocks.map { String($0.content.characters) }.joined(), parsedText(text))
    }

    func testEarlyNewlineAndLaterSpacesKeepUniquePieceIdentitiesWhenSharingACell() {
        let text = "```text\n" + String(repeating: "a", count: 99) + "\n"
            + String(repeating: "b ", count: 940) + String(repeating: "c", count: 2_500) + "\n```"
        let chunks = ToasttyMarkdownChunking.split(text)
        XCTAssertTrue(chunks.contains { $0.blocks.count > 1 }, "Exercise continuations sharing a cell")
        for chunk in chunks {
            XCTAssertEqual(Set(chunk.blocks.map(\.id)).count, chunk.blocks.count)
        }
        XCTAssertEqual(renderedText(chunks), parsedText(text))
    }

    func testHeadingMovesWithFollowingContent() {
        let text = String(repeating: "lead ", count: 355) + "\n\n## Section\n\n"
            + String(repeating: "body ", count: 315) + "\n\n" + String(repeating: "tail ", count: 75)
        let chunks = ToasttyMarkdownChunking.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertFalse(chunks.contains { $0.blocks.last?.style == .heading(level: 2) })
        XCTAssertEqual(renderedText(chunks), parsedText(text))
    }

    private func renderedText(_ chunks: [ToasttyMarkdownChunk]) -> String {
        chunks.flatMap(\.blocks).map { String($0.content.characters) }.joined()
    }

    private func parsedText(_ text: String) -> String {
        ToasttyMarkdownParser.parse(text).map { String($0.content.characters) }.joined()
    }
}
