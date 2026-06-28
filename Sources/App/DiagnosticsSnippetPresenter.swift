import AppKit
import Foundation

enum DiagnosticsSnippetGenerator {
    static let fallbackCLIPath = "/Applications/Toastty.app/Contents/Helpers/toastty"

    static func snippet(cliPath: String? = ToasttyBundledExecutableLocator.defaultCLIExecutablePath()) -> String {
        let bakedPath = shellSingleQuoted(cliPath?.isEmpty == false ? cliPath! : fallbackCLIPath)
        return """
        I'm hitting an issue in Toastty and want to gather a diagnostic report.

        TC="$(command -v toastty || printf '%s\\n' \(bakedPath))"
        TMPBASE="${TMPDIR:-/tmp}"
        TMPBASE="${TMPBASE%/}"
        umask 077
        PROBE="$(mktemp "$TMPBASE/toastty-probe.XXXXXX")"
        DOCTOR="$(mktemp "$TMPBASE/toastty-doctor.XXXXXX")"
        DIAG="$(mktemp "$TMPBASE/toastty-diag.XXXXXX")"
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
          --note "<one line: what's been going wrong this session>" \\
          --out "$DIAG" || COLLECT_EXIT=$?

        printf '\\nTOASTTY_CLI_RESOLVED=%s\\n' "$TC"
        printf 'TOASTTY_DOCTOR_JSON=%s\\n' "$DOCTOR"
        printf 'TOASTTY_DOCTOR_EXIT=%s\\n' "$DOCTOR_EXIT"
        printf 'TOASTTY_DIAGNOSTICS_JSON=%s\\n' "$DIAG"
        printf 'TOASTTY_DIAGNOSTICS_EXIT=%s\\n' "$COLLECT_EXIT"

        Then show me the contents of the doctor JSON file, the diagnostics collection exit code, the diagnostics summary it printed, and the contents of the diagnostics JSON file if collection succeeded so I can review what was collected.
        If I say yes after reviewing it, submit that exact file with:
          "$TC" diagnostics submit --file "$DIAG" --yes
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
        alert.informativeText = "The snippet runs Toastty doctor, creates a local redacted diagnostics JSON file, and asks your agent to show it back before anything is sent."
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
