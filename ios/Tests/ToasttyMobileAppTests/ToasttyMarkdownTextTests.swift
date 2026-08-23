import Foundation
import SwiftUI
import XCTest
@testable import ToasttyMobileApp

@MainActor
final class ToasttyMarkdownTextTests: XCTestCase {
    func testNestedPlanningSummaryProducesParagraphsAndNestedListBlocks() {
        let source = """
        Latest commit: `e9763e53` — “Revise control plane and BYOK implementation plans”

        It adds two planning documents:

        - `plans/plan_byok-model-access_080626.md`
          - BYOK Anthropic/OpenAI keys for beta users
          - AES-256-GCM credential storage
          - API, UI, migration, testing, and release phases
        - `plans/plan_control-plane-disk-removal_080626.md`
          - Stateless Render deployment architecture
          - Turso/libSQL control-plane migration
          - Disk-removal, backup, migration, and validation phases

        No production code was changed, and no test execution is indicated.
        """

        let blocks = ToasttyMarkdownText.blocks(source)
        let listBlocks = blocks.filter {
            if case .list = $0.style { return true }
            return false
        }

        XCTAssertEqual(listBlocks.count, 8)
        XCTAssertEqual(listBlocks[0].style, .list(marker: .bullet, depth: 1))
        XCTAssertEqual(listBlocks[1].style, .list(marker: .bullet, depth: 2))
        XCTAssertEqual(
            String(listBlocks[0].content.characters),
            "plans/plan_byok-model-access_080626.md"
        )
        XCTAssertEqual(
            blocks.flatMap { inlineCodeRuns(in: $0.content) },
            [
                "e9763e53",
                "plans/plan_byok-model-access_080626.md",
                "plans/plan_control-plane-disk-removal_080626.md",
            ]
        )
    }

    func testHeadingAndFencedCodeKeepSemanticStyleAndCodeLineBreaks() {
        let source = """
        ## Result

        ```swift
        let product = left_value * rightValue
        [literal](not-a-link)
        ```
        """

        let blocks = ToasttyMarkdownText.blocks(source)

        XCTAssertEqual(blocks.map(\.style), [
            .heading(level: 2),
            .code(language: "swift"),
        ])
        XCTAssertEqual(
            String(blocks[1].content.characters),
            "let product = left_value * rightValue\n[literal](not-a-link)\n"
        )
        XCTAssertTrue(inlineCodeRuns(in: blocks[1].content).isEmpty)
    }

    func testInlineCodeSpansCarryAccentTintButFencedCodeStaysPlain() {
        let source = """
        Run `sv exec` before generating.

        ```bash
        tuist generate --no-open
        ```
        """

        let blocks = ToasttyMarkdownText.blocks(source)
        XCTAssertEqual(blocks.count, 2)

        let paragraph = blocks[0].content
        let codeRun = paragraph.runs.first {
            $0.inlinePresentationIntent?.contains(.code) == true
        }
        XCTAssertEqual(codeRun?.foregroundColor, ToasttyDesignTokens.amberText)
        XCTAssertEqual(codeRun?.backgroundColor, ToasttyDesignTokens.chipSurface)

        let proseRun = paragraph.runs.first {
            $0.inlinePresentationIntent?.contains(.code) != true
        }
        XCTAssertNil(proseRun?.foregroundColor)
        XCTAssertNil(proseRun?.backgroundColor)

        XCTAssertFalse(blocks[1].content.runs.contains {
            $0.foregroundColor != nil || $0.backgroundColor != nil
        }, "Fenced code keeps the block-level styling only")
    }

    private func inlineCodeRuns(in attributed: AttributedString) -> [String] {
        attributed.runs.compactMap { run in
            guard run.inlinePresentationIntent?.contains(.code) == true else { return nil }
            return String(attributed[run.range].characters)
        }
    }
}
