import Foundation

enum DiagnosticsSkillHandoffGenerator {
    static let skillName = "toastty-send-diagnostics"

    static func bundledSkillPath(bundle: Bundle = .main) -> String? {
        ToasttyAgentPluginBundle.bundledPluginURL(bundle: bundle)?
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(skillName, isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
            .path
    }

    static func prompt(skillPath: String, cliPath: String) -> String {
        """
        I want to send Toastty diagnostics.

        Read and follow the Toastty diagnostics skill at:
        \(skillPath)

        Use this Toastty CLI:
        \(cliPath)

        Use these exact bundled paths. If either is inaccessible, stop and tell me.
        """
    }
}
