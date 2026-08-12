import CoreState
import Foundation

/// Materializes a commented starter script for the global agent hook at
/// `<config-dir>/hooks/agent-hook`. The template is written once and never
/// overwritten, and stays inert until the user points the `agent-hook`
/// config key at it. For runtime-isolated instances the hooks directory
/// resolves under the runtime home, so dev runs never touch the real
/// `~/.toastty`.
enum AgentHookTemplateFile {
    private static let hooksDirectoryName = "hooks"
    private static let fileName = "agent-hook"

    static func fileURL(
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
        return runtimePaths.configDirectoryURL
            .appending(path: hooksDirectoryName, directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }

    static func ensureTemplateExists(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let url = fileURL(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = Data(templateContents().utf8)
        do {
            try contents.write(to: url, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return
        }
        // The hook contract requires a directly executable script; a fresh
        // template should be runnable the moment the user enables it.
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }

    static func templateContents() -> String {
        """
        #!/bin/bash
        #
        # Toastty agent hook — starter template (a safe no-op until you edit it).
        #
        # Toastty created this file once and will never overwrite it. To enable
        # it, set this in your Toastty config (~/.toastty/config):
        #
        #   agent-hook = "~/.toastty/hooks/agent-hook"
        #
        # then run Toastty > Reload Configuration. The file must stay executable
        # and keep a valid shebang on line 1: Toastty executes it directly, not
        # through a shell.
        #
        # Full contract:
        # https://github.com/figelwump/toastty/blob/main/docs/agent-hooks.md
        #
        # How Toastty calls this script:
        # - One global hook for every managed session (codex, claude, opencode,
        #   mimocode, pi, and process watch). There is no per-agent hook
        #   configuration and no raw provider-event passthrough.
        # - The event JSON (schema v1) is written to stdin, then stdin is
        #   closed. The same values arrive as TOASTTY_* environment variables,
        #   so simple scripts can skip JSON parsing.
        # - stdout and stderr are discarded; write to a file if you need logs.
        # - Each invocation gets a 10-second window, then SIGTERM, then SIGKILL
        #   after a one-second grace period. Background children are this
        #   script's responsibility.
        # - Events for one session run strictly in order; different sessions
        #   run concurrently (at most four hook processes globally, and at most
        #   8 queued events per session with lifecycle events prioritized).
        # - Delivery is best-effort around app quit. After relaunch, restored
        #   sessions emit a fresh session-start with launch reason "restore",
        #   so treat any state you keep as re-derivable rather than assuming
        #   you saw every event.
        #
        # Environment variables (always set; optional values may be empty):
        #   TOASTTY_HOOK_SCHEMA_VERSION  currently "1"
        #   TOASTTY_HOOK_EVENT     session-start | turn-complete |
        #                          needs-approval | session-error | session-stop
        #   TOASTTY_AGENT          lowercase agent ID (codex, claude,
        #                          process-watch, ...)
        #   TOASTTY_SESSION_ID     managed session UUID
        #   TOASTTY_WORKSPACE_ID   workspace UUID
        #   TOASTTY_PANEL_ID       panel UUID
        #   TOASTTY_SESSION_CWD    session working directory, or empty
        #   TOASTTY_CLI_PATH       absolute path of this Toastty instance's
        #                          staged CLI, or empty
        #   TOASTTY_SOCKET_PATH    this Toastty instance's automation socket
        #   TOASTTY_LAUNCH_REASON  managed | restore | process-watch for
        #                          session-start; empty otherwise
        #
        # stdin JSON payload (schema v1; ignore unknown fields):
        #   {
        #     "schemaVersion": 1,
        #     "event": "turn-complete",
        #     "timestamp": "2026-08-06T20:15:30.123Z",
        #     "sessionID": "...", "agent": "codex",
        #     "workspaceID": "...", "panelID": "...",
        #     "cwd": "/repo",
        #     "previousStatus": "working",
        #     "newStatus": "ready",
        #     "launchReason": null
        #   }
        #   previousStatus/newStatus are accepted status kinds: idle, working,
        #   needs_approval, ready, error. Both are null for session-start; for
        #   session-stop, previousStatus is the last kind and newStatus is null.
        #
        # Calling back into Toastty:
        # TOASTTY_CLI_PATH and TOASTTY_SOCKET_PATH always target the exact
        # Toastty instance that invoked this hook, including runtime-isolated
        # dev instances. Per-session serialization means callbacks for the same
        # session never overlap. Annotation colors: neutral, green, amber, red,
        # violet, blue, or #RRGGBB. Full action catalog:
        # https://github.com/figelwump/toastty/blob/main/docs/cli-reference.md

        set -euo pipefail

        # The full event JSON. Drain stdin even when unused.
        payload=$(cat)

        case "$TOASTTY_HOOK_EVENT" in
        session-start)
            # A managed session started. TOASTTY_LAUNCH_REASON distinguishes
            # managed, restore, and process-watch starts.
            #
            # Example: show a status chip under the workspace name. Use a
            # stable semantic key (key=agent) so later events update the same
            # chip and preserve its first-use global color.
            # "$TOASTTY_CLI_PATH" action run workspace.set-annotation \\
            #     --workspace "$TOASTTY_WORKSPACE_ID" \\
            #     key=agent text="$TOASTTY_AGENT working"
            ;;
        turn-complete)
            # The session became ready/actionable after working,
            # needs_approval, or error. Held while background children are
            # still running, so this never fires a false "done".
            #
            # Example: flip the chip to done.
            # "$TOASTTY_CLI_PATH" action run workspace.set-annotation \\
            #     --workspace "$TOASTTY_WORKSPACE_ID" \\
            #     key=agent text="$TOASTTY_AGENT done"
            #
            # Example: desktop notification.
            # osascript -e "display notification \\"$TOASTTY_AGENT finished\\" with title \\"Toastty\\""
            ;;
        needs-approval)
            # The session is waiting on user approval.
            # "$TOASTTY_CLI_PATH" action run workspace.set-annotation \\
            #     --workspace "$TOASTTY_WORKSPACE_ID" \\
            #     key=agent text="$TOASTTY_AGENT waiting on you"
            ;;
        session-error)
            # The session's accepted status became error.
            # "$TOASTTY_CLI_PATH" action run workspace.set-annotation \\
            #     --workspace "$TOASTTY_WORKSPACE_ID" \\
            #     key=agent text="$TOASTTY_AGENT error"
            ;;
        session-stop)
            # The session ended (fired exactly once, from any teardown path).
            # previousStatus in the payload is the last accepted status kind.
            # "$TOASTTY_CLI_PATH" action run workspace.clear-annotation \\
            #     --workspace "$TOASTTY_WORKSPACE_ID" \\
            #     key=agent
            ;;
        esac
        """
            + "\n"
    }
}
