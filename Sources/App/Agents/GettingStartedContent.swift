enum GettingStartedContent {
    static let onboardingPrompt = """
    You are helping me set up Toastty. Please run:

    "$TOASTTY_CLI_PATH" setup guide

    Read the guide, narrate each step, dry-run every setup installer first (pass --dry-run), show me the planned writes, and wait for my explicit OK before rerunning anything with --apply.
    """

    static let shellIntegrationCommand = #""$TOASTTY_CLI_PATH" setup install-shell-integration --dry-run"#
    static let codexStatusHooksCommand = #""$TOASTTY_CLI_PATH" setup install-hooks --agent codex --dry-run"#
    static let skillsListCommand = #""$TOASTTY_CLI_PATH" setup skills list"#
    static let shellIntegrationManualRowBody = "Enable live titles, restored pane history, and manually started agent tracking—including inside tmux and zmx."
    static let shellIntegrationRestartNotice = "After applying, open a new Toastty pane to load the integration; existing nested shells and tmux or zmx sessions may need to restart first."

    static let supportedAgentNames = ["codex", "claude", "cursor-agent", "pi", "opencode", "mimo"]
}
