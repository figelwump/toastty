import AppKit
import Foundation

enum DiagnosticsSnippetGenerator {
    static let fallbackCLIPath = "/Applications/Toastty.app/Contents/Helpers/toastty"

    static func snippet(cliPath: String? = ToasttyBundledExecutableLocator.defaultCLIExecutablePath()) -> String {
        let bakedPath = shellSingleQuoted(cliPath?.isEmpty == false ? cliPath! : fallbackCLIPath)
        return """
        I'm hitting an issue in Toastty and want to gather a diagnostic report.

        BAKED_TOASTTY_CLI=\(bakedPath)
        if [ -n "${TOASTTY_CLI_PATH:-}" ] && [ -x "$TOASTTY_CLI_PATH" ]; then
          TC="$TOASTTY_CLI_PATH"
        elif [ -x "$BAKED_TOASTTY_CLI" ]; then
          TC="$BAKED_TOASTTY_CLI"
        else
          TC="$(command -v toastty || printf '%s\\n' "$BAKED_TOASTTY_CLI")"
        fi
        TMPBASE="${TMPDIR:-/tmp}"
        TMPBASE="${TMPBASE%/}"
        umask 077
        PROBE="$(mktemp "$TMPBASE/toastty-probe.XXXXXX")"
        DOCTOR="$(mktemp "$TMPBASE/toastty-doctor.XXXXXX")"
        DIAG="$(mktemp "$TMPBASE/toastty-diag.XXXXXX")"
        DIAGNOSTICS_NOTE="${TOASTTY_DIAGNOSTICS_NOTE:-User requested Toastty diagnostics; symptom not specified in this prompt.}"
        DOCTOR_EXIT=0
        COLLECT_EXIT=0

        {
          echo "TOASTTY_CLI_PATH=${TOASTTY_CLI_PATH:-<unset>}"
          command -v toastty claude codex pi opencode mimo mimocode
          type -a claude codex pi opencode mimo mimocode
          ls -la ~/.toastty/bin 2>&1
          echo "PATH=$PATH"
        } > "$PROBE" 2>&1

        "$TC" --json doctor > "$DOCTOR" || DOCTOR_EXIT=$?

        "$TC" diagnostics collect \\
          --shell-probe "$PROBE" \\
          --note "$DIAGNOSTICS_NOTE" \\
          --out "$DIAG" || COLLECT_EXIT=$?

        printf '\\nTOASTTY_CLI_RESOLVED=%s\\n' "$TC"
        printf 'TOASTTY_DOCTOR_JSON=%s\\n' "$DOCTOR"
        printf 'TOASTTY_DOCTOR_EXIT=%s\\n' "$DOCTOR_EXIT"
        printf 'TOASTTY_DIAGNOSTICS_JSON=%s\\n' "$DIAG"
        printf 'TOASTTY_DIAGNOSTICS_EXIT=%s\\n' "$COLLECT_EXIT"

        Then show me a concise review before anything is submitted:
        - doctor status and any warn/fail checks
        - diagnostics file path and size
        - diagnostics collection exit code and the summary it printed
        - top-level diagnostics sections
        - redaction rules version and redaction count
        - log sizes, automation audit count, socket state, and any obvious warnings
        - a short privacy summary of what remains in cleartext

        Base the privacy summary on the diagnostics structure, redaction metadata, and printed summary. Do not run broad heuristic grep/token scans over the raw JSON unless a warning, failure, or secret-scan result suggests a problem.
        Do not paste the full diagnostics JSON if it is large. Do not re-run collection just to improve the note unless I explicitly ask.

        Nothing should be submitted until I explicitly approve. When asking for approval, lead with: "If you approve, I'll send these diagnostics to the Toastty developer team. If you'd like them to be able to follow up, tell me your name and email before I submit; anonymous is fine."
        If I provide contact info before submission, include it with --contact. The contact text is uploaded in the submitted diagnostics note in cleartext; do not edit the diagnostics JSON by hand and do not re-run collection just to add contact.
        Shell-quote contact text as one argument when substituting it into the command.
        If I approve, submit the diagnostics file path printed above using the exact CLI path printed above. Run exactly one command:
          With contact: "<TOASTTY_CLI_RESOLVED>" diagnostics submit --file "<TOASTTY_DIAGNOSTICS_JSON>" --yes --contact "<NAME/EMAIL PROVIDED BY USER>"
          Without contact: "<TOASTTY_CLI_RESOLVED>" diagnostics submit --file "<TOASTTY_DIAGNOSTICS_JSON>" --yes
        Omit --contact entirely if I did not provide contact info.

        Do not wrap diagnostics submit in sv exec, sudo, or repo-local helper tooling; this is a user-side submit command and the installed Toastty CLI should carry its upload configuration. Do not rely on $TC or $DIAG still being set in a later shell. Do not re-run collection before submitting. If submit fails because endpoint or upload key is unavailable, show me the exact error and stop.
        """
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

@MainActor
enum DiagnosticsSnippetPresenter {
    static func present(
        cliPathProvider: () -> String? = ToasttyBundledExecutableLocator.defaultCLIExecutablePath
    ) {
        let snippet = DiagnosticsSnippetGenerator.snippet(cliPath: cliPathProvider())
        let alert = NSAlert()
        alert.messageText = "Copy Diagnostics Collection Snippet"
        alert.informativeText = "The snippet runs Toastty doctor, creates a local redacted diagnostics JSON file, and asks your agent to summarize it before anything is sent."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy Snippet")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = snippetAccessoryView(text: snippet)

        if alert.runModal() == .alertFirstButtonReturn {
            copy(snippet)
        }
    }

    private static func copy(_ snippet: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snippet, forType: .string)
    }

    private static func snippetAccessoryView(text: String) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = text
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        return scrollView
    }
}
