import XCTest
@testable import ToasttyApp

final class DiagnosticsSnippetGeneratorTests: XCTestCase {
    func testSnippetShellQuotesBakedCLIPath() {
        let snippet = DiagnosticsSnippetGenerator.snippet(
            cliPath: "/Applications/Toastty Beta.app/Contents/Helpers/toastty"
        )

        XCTAssertTrue(snippet.contains("BAKED_TOASTTY_CLI='/Applications/Toastty Beta.app/Contents/Helpers/toastty'"))
        XCTAssertTrue(snippet.contains("TC=\"$TOASTTY_CLI_PATH\""))
        XCTAssertTrue(snippet.contains("TC=\"$BAKED_TOASTTY_CLI\""))
        XCTAssertTrue(snippet.contains("command -v toastty || printf '%s\\n' \"$BAKED_TOASTTY_CLI\""))
        XCTAssertTrue(snippet.contains("diagnostics collect"))
        XCTAssertTrue(snippet.contains("\"$TC\" --json doctor > \"$DOCTOR\" || DOCTOR_EXIT=$?"))
        XCTAssertTrue(snippet.contains("DOCTOR=\"$(mktemp \"$TMPBASE/toastty-doctor.XXXXXX\")\""))
        XCTAssertTrue(snippet.contains("COLLECT_EXIT=0"))
        XCTAssertTrue(snippet.contains("DIAGNOSTICS_NOTE=\"${TOASTTY_DIAGNOSTICS_NOTE:-User requested Toastty diagnostics; symptom not specified in this prompt.}\""))
        XCTAssertTrue(snippet.contains("TOASTTY_DOCTOR_JSON=%s"))
        XCTAssertTrue(snippet.contains("TOASTTY_DOCTOR_EXIT=%s"))
        XCTAssertTrue(snippet.contains("DIAG=\"$(mktemp \"$TMPBASE/toastty-diag.XXXXXX\")\""))
        XCTAssertTrue(snippet.contains("--note \"$DIAGNOSTICS_NOTE\""))
        XCTAssertTrue(snippet.contains("--out \"$DIAG\" || COLLECT_EXIT=$?"))
        XCTAssertTrue(snippet.contains("TOASTTY_DIAGNOSTICS_EXIT=%s"))
        XCTAssertTrue(snippet.contains("show me a concise review before anything is submitted"))
        XCTAssertTrue(snippet.contains("Do not paste the full diagnostics JSON if it is large."))
        XCTAssertTrue(snippet.contains("Base the privacy summary on the diagnostics structure, redaction metadata, and printed summary."))
        XCTAssertTrue(snippet.contains("Do not run broad heuristic grep/token scans over the raw JSON unless a warning, failure, or secret-scan result suggests a problem."))
        XCTAssertTrue(snippet.contains("I'll send these diagnostics to the Toastty developer team."))
        XCTAssertTrue(snippet.contains("tell me your name and email before I submit; anonymous is fine."))
        XCTAssertTrue(snippet.contains("\"<TOASTTY_CLI_RESOLVED>\" diagnostics submit --file \"<TOASTTY_DIAGNOSTICS_JSON>\" --yes"))
        XCTAssertTrue(snippet.contains("Do not rely on $TC or $DIAG still being set in a later shell."))
        XCTAssertFalse(snippet.contains("contents of the diagnostics JSON file"))
        XCTAssertFalse(snippet.contains("diagnostics submit --file \"$DIAG\" --yes"))
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
