import XCTest
@testable import ToasttyApp

final class DiagnosticsSnippetGeneratorTests: XCTestCase {
    func testSnippetShellQuotesBakedCLIPath() {
        let snippet = DiagnosticsSnippetGenerator.snippet(
            cliPath: "/Applications/Toastty Beta.app/Contents/Helpers/toastty"
        )

        XCTAssertTrue(
            snippet.contains("printf '%s\\n' '/Applications/Toastty Beta.app/Contents/Helpers/toastty'")
        )
        XCTAssertTrue(snippet.contains("diagnostics collect"))
        XCTAssertTrue(snippet.contains("--out /tmp/toastty-diag.json"))
    }

    func testSnippetEscapesSingleQuotesInBakedCLIPath() {
        let snippet = DiagnosticsSnippetGenerator.snippet(
            cliPath: "/tmp/Toastty's Build.app/Contents/Helpers/toastty"
        )

        XCTAssertTrue(
            snippet.contains("'/tmp/Toastty'\\''s Build.app/Contents/Helpers/toastty'")
        )
    }
}
