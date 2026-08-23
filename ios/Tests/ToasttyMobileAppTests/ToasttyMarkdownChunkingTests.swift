import XCTest
@testable import ToasttyMobileApp

final class ToasttyMarkdownChunkingTests: XCTestCase {
    func testShortTextStaysWhole() {
        let text = Array(repeating: "A modest paragraph of body text.", count: 20)
            .joined(separator: "\n\n")
        XCTAssertLessThanOrEqual(text.count, ToasttyMarkdownChunking.chunkThreshold)
        XCTAssertEqual(ToasttyMarkdownChunking.split(text), [text])
    }

    func testLongParagraphsSplitAtBlankLinesAndPreserveContent() {
        let paragraphs = (1 ... 14).map { index in
            "Paragraph \(index): " + Array(repeating: "chunked transcript body", count: 20)
                .joined(separator: " ")
        }
        let text = paragraphs.joined(separator: "\n\n")
        XCTAssertGreaterThan(text.count, ToasttyMarkdownChunking.chunkThreshold)

        let chunks = ToasttyMarkdownChunking.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(separator: "\n\n"), text)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(
                chunk.count,
                ToasttyMarkdownChunking.chunkBudget + 600,
                "Each chunk should stay near the budget"
            )
        }
    }

    func testFencedCodeBlockWithBlankLinesStaysAtomicWhenUnderBudget() {
        let fence = (["```swift", "let a = 1", "", "let b = 2", "```"]).joined(separator: "\n")
        let padding = (1 ... 10).map { index in
            "Padding paragraph \(index): " + Array(repeating: "text", count: 80).joined(separator: " ")
        }
        let text = (padding.prefix(5) + [fence] + padding.suffix(5)).joined(separator: "\n\n")
        XCTAssertGreaterThan(text.count, ToasttyMarkdownChunking.chunkThreshold)

        let chunks = ToasttyMarkdownChunking.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(
            chunks.filter { $0.contains(fence) }.count,
            1,
            "A fence under budget must land intact inside exactly one chunk"
        )
        XCTAssertEqual(chunks.joined(separator: "\n\n"), text)
    }

    func testOversizedFenceSplitsIntoRefencedChunksThatStillParseAsCode() {
        let interior = (1 ... 120).map { "let fixtureValue\($0) = transcriptFixtureValue(\($0))" }
        let text = (["```swift"] + interior + ["```"]).joined(separator: "\n")
        XCTAssertGreaterThan(text.count, ToasttyMarkdownChunking.chunkThreshold)

        let chunks = ToasttyMarkdownChunking.split(text)
        XCTAssertGreaterThan(chunks.count, 1)

        var recombinedInterior: [String] = []
        for chunk in chunks {
            let lines = chunk.split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.first, "```swift")
            XCTAssertEqual(lines.last, "```")
            recombinedInterior.append(contentsOf: lines.dropFirst().dropLast())

            let blocks = ToasttyMarkdownText.blocks(chunk)
            XCTAssertEqual(blocks.count, 1)
            guard case .code(let language) = blocks[0].style else {
                return XCTFail("A re-fenced chunk must still parse as a code block")
            }
            XCTAssertEqual(language, "swift")
        }
        XCTAssertEqual(recombinedInterior, interior)
    }

    func testSingleGiantLineSplitsAtWhitespace() {
        let words = (1 ... 900).map { "word\($0)" }
        let text = words.joined(separator: " ")
        XCTAssertGreaterThan(text.count, ToasttyMarkdownChunking.chunkThreshold)

        let chunks = ToasttyMarkdownChunking.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(
            chunks.joined(separator: " ").split(separator: " ").map(String.init),
            words,
            "Whitespace splitting must not drop or mangle any word"
        )
    }

    func testHeadingIsNotStrandedAtChunkEnd() {
        let first = "Lead paragraph: " + Array(repeating: "body", count: 355).joined(separator: " ")
        let heading = "## Section"
        let second = "Section paragraph: " + Array(repeating: "body", count: 315).joined(separator: " ")
        let third = "Tail paragraph: " + Array(repeating: "body", count: 75).joined(separator: " ")
        let text = [first, heading, second, third].joined(separator: "\n\n")
        XCTAssertGreaterThan(text.count, ToasttyMarkdownChunking.chunkThreshold)

        let chunks = ToasttyMarkdownChunking.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertFalse(
                chunk.hasSuffix(heading),
                "A heading must move to the chunk holding the content it titles"
            )
        }
        XCTAssertTrue(chunks.contains { $0.hasPrefix(heading) })
        XCTAssertEqual(chunks.joined(separator: "\n\n"), text)
    }
}
