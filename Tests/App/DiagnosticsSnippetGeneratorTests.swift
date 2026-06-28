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
        XCTAssertTrue(snippet.contains("\"$TC\" --json doctor > \"$DOCTOR\" || DOCTOR_EXIT=$?"))
        XCTAssertTrue(snippet.contains("DOCTOR=\"$(mktemp \"$TMPBASE/toastty-doctor.XXXXXX\")\""))
        XCTAssertTrue(snippet.contains("COLLECT_EXIT=0"))
        XCTAssertTrue(snippet.contains("TOASTTY_DOCTOR_JSON=%s"))
        XCTAssertTrue(snippet.contains("TOASTTY_DOCTOR_EXIT=%s"))
        XCTAssertTrue(snippet.contains("DIAG=\"$(mktemp \"$TMPBASE/toastty-diag.XXXXXX\")\""))
        XCTAssertTrue(snippet.contains("--out \"$DIAG\" || COLLECT_EXIT=$?"))
        XCTAssertTrue(snippet.contains("TOASTTY_DIAGNOSTICS_EXIT=%s"))
        XCTAssertTrue(snippet.contains("diagnostics submit --file \"$DIAG\" --yes"))
        XCTAssertTrue(snippet.contains("umask 077"))
        XCTAssertTrue(snippet.contains("command -v toastty claude codex pi opencode mimo mimocode"))
        XCTAssertTrue(snippet.contains("type -a claude codex pi opencode mimo mimocode"))
        XCTAssertFalse(snippet.contains(" cdx"))
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
