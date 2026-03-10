import Foundation

public enum ToasttyLaunchContextEnvironment {
    public static let agentKey = "TOASTTY_AGENT"
    public static let sessionIDKey = "TOASTTY_SESSION_ID"
    public static let panelIDKey = "TOASTTY_PANEL_ID"
    public static let cwdKey = "TOASTTY_CWD"
    public static let repoRootKey = "TOASTTY_REPO_ROOT"
    public static let socketPathKey = "TOASTTY_SOCKET_PATH"
    public static let cliPathKey = "TOASTTY_CLI_PATH"
    public static let agentRunSkipSessionStartKey = "__TOASTTY_INTERNAL_AGENT_RUN_SKIP_SESSION_START"
}
