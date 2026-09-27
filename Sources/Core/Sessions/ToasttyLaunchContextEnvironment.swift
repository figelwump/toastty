import Foundation

public enum ToasttyLaunchContextEnvironment {
    public static let agentKey = "TOASTTY_AGENT"
    public static let agentBasePathKey = "TOASTTY_AGENT_BASE_PATH"
    public static let sessionIDKey = "TOASTTY_SESSION_ID"
    public static let panelIDKey = "TOASTTY_PANEL_ID"
    public static let launchReasonKey = "TOASTTY_LAUNCH_REASON"
    /// Why a restored pane did not resume its agent; the pane prints it once.
    public static let restoreNoticeKey = "TOASTTY_RESTORE_NOTICE"
    public static let cwdKey = "TOASTTY_CWD"
    public static let repoRootKey = "TOASTTY_REPO_ROOT"
    public static let socketPathKey = "TOASTTY_SOCKET_PATH"
    public static let cliPathKey = "TOASTTY_CLI_PATH"
    public static let appResourcesPathKey = "TOASTTY_APP_RESOURCES_PATH"
    public static let paneJournalFileKey = "TOASTTY_PANE_JOURNAL_FILE"
    public static let agentShimDirectoryKey = "TOASTTY_AGENT_SHIM_DIR"
    public static let managedAgentShimBypassKey = "TOASTTY_MANAGED_AGENT_SHIM_BYPASS"
    public static let managedAgentArtifactOwnerFileKey = "TOASTTY_MANAGED_ARTIFACT_OWNER_FILE"
    public static let skillsRootKey = "TOASTTY_SKILLS_ROOT"
    public static let userSkillsRootKey = "TOASTTY_USER_SKILLS_ROOT"
}
