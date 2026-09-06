import Foundation
import XCTest
@testable import ToasttyMobileApp

@MainActor
final class ToasttyMarkdownTableTests: XCTestCase {
    func testTableBetweenParagraphsKeepsHeaderCellsAndInlineFormatting() throws {
        let blocks = ToasttyMarkdownParser.parse("""
        There are three distinct responsibilities:

        | Component | Responsibility |
        | --- | --- |
        | **Host** | Owns the `session` |
        | iOS | Displays the [transcript][docs] |
        | Gateway | Carries updates |

        After the table.

        [docs]: https://example.com/transcript
        """)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.first?.style, .paragraph)
        XCTAssertEqual(blocks.last?.style, .paragraph)
        let table = try table(in: blocks[1])
        XCTAssertEqual(table.columns, [.leading, .leading])
        XCTAssertEqual(table.rows.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(strings(table.rows[0]), ["Component", "Responsibility"])
        XCTAssertTrue(table.rows[0].isHeader)
        XCTAssertTrue(table.rows[1].cells[0].runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertTrue(table.rows[1].cells[1].runs.contains {
            $0.inlinePresentationIntent?.contains(.code) == true
        })
        XCTAssertEqual(table.rows[2].cells[1].runs.compactMap(\.link), [URL(string: "https://example.com/transcript")!])
    }

    func testAlignmentAndEmptyCellsPreserveColumnPositionsAndInternalEmptyRows() throws {
        let blocks = ToasttyMarkdownParser.parse("""
        | | Center | Right |
        | :--- | :---: | ---: |
        | a | | c |
        | | | |
        | | e | |
        """)
        let table = try table(in: XCTUnwrap(blocks.first))
        XCTAssertEqual(table.columns, [.leading, .center, .trailing])
        XCTAssertEqual(table.rows.map(strings), [
            ["", "Center", "Right"], ["a", "", "c"], ["", "", ""], ["", "e", ""],
        ])
    }

    func testSeparateTablesDoNotMergeRowsOrColumnDefinitions() throws {
        let blocks = ToasttyMarkdownParser.parse("""
        | First | Value |
        | --- | --- |
        | A | One |

        | Second | Count | Notes |
        | --- | ---: | --- |
        | B | 2 | Two |
        """)
        XCTAssertEqual(blocks.count, 2)
        let first = try table(in: blocks[0])
        let second = try table(in: blocks[1])
        XCTAssertEqual(first.columns.count, 2)
        XCTAssertEqual(second.columns, [.leading, .trailing, .leading])
        XCTAssertEqual(strings(first.rows[1]), ["A", "One"])
        XCTAssertEqual(strings(second.rows[1]), ["B", "2", "Two"])
    }

    func testLongMessageSplitsTablesBetweenRowsWithRepeatedHeadersAndUniqueBlockIDs() throws {
        let rows = (1...60).map { "| Row \($0) | " + String(repeating: "detail ", count: 16) + "|" }
        let text = "Introduction\n\n| Name | Detail |\n| --- | --- |\n" + rows.joined(separator: "\n") + "\n\nConclusion"
        let whole = try XCTUnwrap(ToasttyMarkdownParser.parse(text).compactMap { block -> ToasttyMarkdownTable? in
            guard case .table(let table) = block.style else { return nil }
            return table
        }.first)
        let chunks = ToasttyMarkdownChunking.split(text)
        let blocks = chunks.flatMap(\.blocks)
        let tables = blocks.compactMap { block -> ToasttyMarkdownTable? in
            guard case .table(let table) = block.style else { return nil }
            return table
        }
        XCTAssertGreaterThan(tables.count, 1)
        XCTAssertEqual(tables.flatMap { Array($0.rows.dropFirst()) }, Array(whole.rows.dropFirst()))
        XCTAssertTrue(tables.allSatisfy { $0.rows.first == whole.rows.first && $0.columns == whole.columns })
        XCTAssertTrue(tables.allSatisfy { $0.rows.count > 1 && $0.content.characters.count <= ToasttyMarkdownChunking.chunkBudget })
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count)
        XCTAssertEqual(String(try XCTUnwrap(blocks.first).content.characters), "Introduction")
        XCTAssertEqual(String(try XCTUnwrap(blocks.last).content.characters), "Conclusion")
    }

    func testSparseTablesSplitBeforeAccumulatingTooManyRenderedRows() {
        let rows = (1...100).map { index in
            index.isMultiple(of: 2) ? "| | | | | |" : "| x | | | | |"
        }
        let text = "| A | B | C | D | E |\n| --- | --- | --- | --- | --- |\n"
            + rows.joined(separator: "\n") + "\n| End | | | | |"
        XCTAssertLessThan(text.count, ToasttyMarkdownChunking.chunkThreshold)
        let chunks = ToasttyMarkdownChunking.split(text)
        let tables = chunks.flatMap(\.blocks).compactMap { block -> ToasttyMarkdownTable? in
            guard case .table(let table) = block.style else { return nil }
            return table
        }
        XCTAssertGreaterThan(tables.count, 1)
        XCTAssertTrue(tables.allSatisfy { $0.rows.count - 1 <= ToasttyMarkdownTable.maximumBodyRowsPerChunk })
        XCTAssertEqual(chunks.count, tables.count)
        XCTAssertEqual(tables.flatMap { $0.rows.dropFirst().map(\.id) }, Array(1...101))
    }

    func testOversizedRowStaysIntactWithoutAnEmptyTrailingHeaderChunk() throws {
        let longCell = String(repeating: "large cell ", count: 600)
        let text = "| Name | Content |\n| --- | --- |\n| Huge | \(longCell) |\n| Small | End |"
        let tables = ToasttyMarkdownChunking.split(text).flatMap(\.blocks).compactMap { block -> ToasttyMarkdownTable? in
            guard case .table(let table) = block.style else { return nil }
            return table
        }
        XCTAssertEqual(tables.count, 2)
        XCTAssertEqual(tables.map { $0.rows.count }, [2, 2])
        XCTAssertEqual(strings(tables[0].rows[1]), ["Huge", longCell.trimmingCharacters(in: .whitespaces)])
        XCTAssertEqual(strings(tables[1].rows[1]), ["Small", "End"])
    }

    func testPipesInsideCodeFenceStayCode() {
        let blocks = ToasttyMarkdownParser.parse("```text\n| A | B |\n| --- | --- |\n| x | y |\n```")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].style, .code(language: "text"))
    }

    func testTableCellLinksAndInlineCodeUseExistingTranscriptStyles() throws {
        let blocks = ToasttyMarkdownText.blocks("| Link | Code |\n| --- | --- |\n| [Docs](https://example.com) | `value` |")
        let table = try table(in: XCTUnwrap(blocks.first))
        XCTAssertTrue(table.rows[1].cells[0].runs.contains { $0.link != nil && $0.foregroundColor != nil })
        XCTAssertTrue(table.rows[1].cells[1].runs.contains {
            $0.inlinePresentationIntent?.contains(.code) == true && $0.backgroundColor != nil
        })
    }

    private func table(in block: ToasttyMarkdownBlock) throws -> ToasttyMarkdownTable {
        guard case .table(let table) = block.style else {
            throw NSError(domain: "ExpectedMarkdownTable", code: 1)
        }
        return table
    }

    private func strings(_ row: ToasttyMarkdownTable.Row) -> [String] {
        row.cells.map { String($0.characters) }
    }
}
