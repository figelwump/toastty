import AppKit
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

        Read and follow the Toastty diagnostics skill at this exact filesystem path:
        \(skillPath)

        For every command in that skill, use this exact Toastty CLI executable path:
        \(cliPath)

        This is a direct handoff to the skill bundled with the running Toastty app. Do not rely on skill discovery or TOASTTY_SKILLS_ROOT. The two lines above are literal filesystem paths with no quotes included; shell-quote each path when using it in a command. Show me the collected diagnostics review and wait for my explicit approval before uploading anything. Submit anonymously unless I explicitly provide contact text for this report; never infer or discover contact information. If either path is inaccessible, stop and show me the exact error instead of guessing another path or workflow.
        """
    }
}

@MainActor
enum DiagnosticsPresenter {
    static func present(
        cliPathProvider: () -> String? = ToasttyBundledExecutableLocator.defaultCLIExecutablePath,
        skillPathProvider: () -> String? = { DiagnosticsSkillHandoffGenerator.bundledSkillPath() },
        fileManager: FileManager = .default
    ) {
        guard let skillPath = skillPathProvider(),
              fileManager.isReadableFile(atPath: skillPath) else {
            presentUnavailable(
                detail: "Toastty could not read its bundled diagnostics skill. Restart Toastty or reinstall the current version, then try again."
            )
            return
        }

        guard let cliPath = cliPathProvider(),
              fileManager.isExecutableFile(atPath: cliPath) else {
            presentUnavailable(
                detail: "Toastty could not find the diagnostics CLI bundled with this running app. Restart Toastty or reinstall the current version, then try again."
            )
            return
        }

        let prompt = DiagnosticsSkillHandoffGenerator.prompt(
            skillPath: skillPath,
            cliPath: cliPath
        )
        let alert = NSAlert()
        alert.messageText = "Send Toastty Diagnostics"
        alert.informativeText = "Copy these instructions into an agent session. The agent will collect a redacted report locally, show you a review, and wait for your approval before sending anything."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy Instructions")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = promptAccessoryView(text: prompt)

        if alert.runModal() == .alertFirstButtonReturn {
            copy(prompt)
        }
    }

    private static func presentUnavailable(detail: String) {
        let alert = NSAlert()
        alert.messageText = "Diagnostics Instructions Unavailable"
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func copy(_ prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
    }

    private static func promptAccessoryView(text: String) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 180))
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
