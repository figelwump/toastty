#if TOASTTY_HAS_GHOSTTY_KIT
import CoreState
import Foundation

@MainActor
final class TerminalActivityInferenceService {
    private struct PanelActivityState {
        var workspaceID: UUID
        var agent: AgentKindInference
        var phase: AgentActivityPhase
        var runningCommand: String?
        var updatedAt: Date
    }

    private enum AgentKindInference {
        case codex
        case claudeCode
    }

    private enum AgentActivityPhase {
        case running
        case waitingInput
        case idle
    }

    private let readVisibleText: (UUID) -> String?
    // Keep inferred agent labels out of persisted terminal metadata. The pane
    // header reads from this transient override and falls back to terminal
    // title/CWD metadata when no override is present.
    private(set) var panelDisplayTitleOverrideByID: [UUID: String] = [:]
    private var panelActivityByPanelID: [UUID: PanelActivityState] = [:]
    private(set) var workspaceActivitySubtextByID: [UUID: String] = [:]

    init(readVisibleText: @escaping (UUID) -> String?) {
        self.readVisibleText = readVisibleText
    }

    func invalidate(panelID: UUID) {
        panelDisplayTitleOverrideByID.removeValue(forKey: panelID)
        panelActivityByPanelID.removeValue(forKey: panelID)
    }

    func synchronizeLivePanels(_ livePanelIDs: Set<UUID>, liveWorkspaceIDs: Set<UUID>) {
        panelDisplayTitleOverrideByID = panelDisplayTitleOverrideByID.filter { panelID, _ in
            livePanelIDs.contains(panelID)
        }
        panelActivityByPanelID = panelActivityByPanelID.filter { panelID, _ in
            livePanelIDs.contains(panelID)
        }
        refreshWorkspaceActivitySubtext(liveWorkspaceIDs: liveWorkspaceIDs)
    }

    func panelDisplayTitleOverride(for panelID: UUID) -> String? {
        panelDisplayTitleOverrideByID[panelID]
    }

    func workspaceActivitySubtext(for workspaceID: UUID) -> String? {
        workspaceActivitySubtextByID[workspaceID]
    }

    func refreshWorkspaceActivitySubtext(liveWorkspaceIDs: Set<UUID>) {
        let now = Date()
        pruneStalePanelActivity(now: now)
        workspaceActivitySubtextByID = nextWorkspaceActivitySubtext(
            liveWorkspaceIDs: liveWorkspaceIDs,
            now: now
        )
    }

    func refreshVisibleTextInference(
        state: AppState,
        selectedPanelWorkspaceIDs: [UUID: UUID],
        backgroundPanelWorkspaceIDs: [UUID: UUID]
    ) {
        for (panelID, workspaceID) in selectedPanelWorkspaceIDs {
            refreshPanelDisplayTitleOverrideFromVisibleTextIfNeeded(
                panelID: panelID,
                workspaceID: workspaceID,
                state: state
            )
        }

        let now = Date()
        for (panelID, workspaceID) in selectedPanelWorkspaceIDs {
            refreshPanelActivityFromVisibleTextIfNeeded(
                panelID: panelID,
                workspaceID: workspaceID,
                state: state,
                now: now
            )
        }

        for (panelID, workspaceID) in backgroundPanelWorkspaceIDs {
            refreshPanelActivityFromVisibleTextIfNeeded(
                panelID: panelID,
                workspaceID: workspaceID,
                state: state,
                now: now
            )
        }

        pruneStalePanelActivity(now: now)
        updateWorkspaceActivitySubtext(state: state, now: now)
    }

    private func refreshPanelDisplayTitleOverrideFromVisibleTextIfNeeded(
        panelID: UUID,
        workspaceID: UUID,
        state: AppState
    ) {
        guard let workspace = state.workspacesByID[workspaceID],
              let panelState = workspace.panels[panelID],
              case .terminal(let terminalState) = panelState else {
            panelDisplayTitleOverrideByID.removeValue(forKey: panelID)
            return
        }

        let currentTitle = terminalState.title
        let legacyAgentTitle = Self.canonicalInferredAgentTitle(from: currentTitle)
        let titleEligibleForInference = Self.titleIsEligibleForAgentInference(
            terminalTitle: currentTitle,
            terminalCWD: terminalState.cwd
        )
        guard legacyAgentTitle != nil || titleEligibleForInference else {
            panelDisplayTitleOverrideByID.removeValue(forKey: panelID)
            return
        }

        guard let visibleText = readVisibleText(panelID) else {
            return
        }
        if Self.visibleTextShowsIdleShellPrompt(visibleText) {
            panelDisplayTitleOverrideByID.removeValue(forKey: panelID)
            return
        }

        if let inferredAgentTitle = Self.inferredAgentDisplayTitle(
            visibleText: visibleText,
            legacyAgentTitle: legacyAgentTitle
        ) {
            publishPanelDisplayTitleOverride(
                inferredAgentTitle,
                panelID: panelID,
                workspaceID: workspaceID,
                inferenceSource: "agent"
            )
            return
        }

        if titleEligibleForInference,
           let inferredRunningCommand = TerminalVisibleTextInspector.inferredRunningCommand(visibleText) {
            publishPanelDisplayTitleOverride(
                inferredRunningCommand,
                panelID: panelID,
                workspaceID: workspaceID,
                inferenceSource: "running_command"
            )
            return
        }

        // Visible-text inspection can miss banner text or the original prompt
        // command transiently while output continues to stream. Keep any
        // existing override until the shell returns to an idle prompt or a
        // semantic terminal title arrives and suppresses title inference.
    }

    private func refreshPanelActivityFromVisibleTextIfNeeded(
        panelID: UUID,
        workspaceID: UUID,
        state: AppState,
        now: Date
    ) {
        guard let workspace = state.workspacesByID[workspaceID],
              let panelState = workspace.panels[panelID],
              case .terminal(let terminalState) = panelState else {
            panelActivityByPanelID.removeValue(forKey: panelID)
            return
        }

        guard let visibleText = readVisibleText(panelID) else {
            return
        }
        let visibleLines = TerminalVisibleTextInspector.sanitizedLines(visibleText)

        let inferredAgentKind = Self.inferredAgentKind(
            terminalTitle: terminalState.title,
            visibleText: visibleText
        )
        guard let inferredAgentKind else {
            // Clear stale agent activity after the slot returns to an idle
            // shell prompt. This avoids lingering sidebar status while also
            // tolerating transient inference misses mid-run.
            if Self.visibleTextShowsIdleShellPrompt(visibleText) {
                panelActivityByPanelID.removeValue(forKey: panelID)
            }
            return
        }

        let inferredPhase = Self.inferredAgentPhase(visibleText: visibleText, visibleLines: visibleLines)
        let inferredRunningCommand = TerminalVisibleTextInspector.inferredRunningCommand(visibleText)
        panelActivityByPanelID[panelID] = PanelActivityState(
            workspaceID: workspaceID,
            agent: inferredAgentKind,
            phase: inferredPhase,
            runningCommand: inferredRunningCommand,
            updatedAt: now
        )
    }

    private func pruneStalePanelActivity(now: Date) {
        panelActivityByPanelID = panelActivityByPanelID.filter { _, activity in
            now.timeIntervalSince(activity.updatedAt) <= Self.activityRetentionInterval
        }
    }

    private func publishPanelDisplayTitleOverride(
        _ inferredTitle: String,
        panelID: UUID,
        workspaceID: UUID,
        inferenceSource: String
    ) {
        guard panelDisplayTitleOverrideByID[panelID] != inferredTitle else {
            return
        }
        panelDisplayTitleOverrideByID[panelID] = inferredTitle
        ToasttyLog.debug(
            "Updated transient inferred display title from visible terminal text",
            category: .terminal,
            metadata: [
                "workspace_id": workspaceID.uuidString,
                "panel_id": panelID.uuidString,
                "inferred_title": inferredTitle,
                "inference_source": inferenceSource,
            ]
        )
    }

    private func updateWorkspaceActivitySubtext(state: AppState, now: Date) {
        pruneStalePanelActivity(now: now)
        workspaceActivitySubtextByID = nextWorkspaceActivitySubtext(
            liveWorkspaceIDs: Set(state.workspacesByID.keys),
            now: now
        )
    }

    private func nextWorkspaceActivitySubtext(
        liveWorkspaceIDs: Set<UUID>,
        now: Date
    ) -> [UUID: String] {
        var activitiesByWorkspaceID: [UUID: [PanelActivityState]] = [:]
        for activity in panelActivityByPanelID.values {
            guard liveWorkspaceIDs.contains(activity.workspaceID) else { continue }
            guard now.timeIntervalSince(activity.updatedAt) <= Self.activityRetentionInterval else { continue }
            activitiesByWorkspaceID[activity.workspaceID, default: []].append(activity)
        }

        var nextSubtextByWorkspaceID: [UUID: String] = [:]
        for (workspaceID, activities) in activitiesByWorkspaceID {
            guard let subtext = Self.workspaceActivitySubtext(from: activities, now: now) else { continue }
            nextSubtextByWorkspaceID[workspaceID] = subtext
        }
        return nextSubtextByWorkspaceID
    }

    private static func inferredAgentTitleFromVisibleTerminalText(_ visibleText: String) -> String? {
        let lines = TerminalVisibleTextInspector.sanitizedLines(visibleText)
        guard lines.isEmpty == false else { return nil }
        let candidateLines = Array(lines.suffix(agentTitleDetectionLineWindow))

        for line in candidateLines.reversed() {
            let lowercasedLine = line.lowercased()
            if lowercasedLine.contains("openai codex (v") {
                return "Codex"
            }
            if lowercasedLine.contains("claude code v") {
                return "Claude Code"
            }
        }
        return nil
    }

    private static func inferredAgentDisplayTitle(
        visibleText: String,
        legacyAgentTitle: String?
    ) -> String? {
        if let inferredBannerTitle = inferredAgentTitleFromVisibleTerminalText(visibleText) {
            return inferredBannerTitle
        }

        if let token = TerminalVisibleTextInspector.recentPromptCommandToken(visibleText),
           let agent = agentKind(forPromptToken: token) {
            switch agent {
            case .codex:
                return "Codex"
            case .claudeCode:
                return "Claude Code"
            }
        }

        // Preserve exact legacy inferred titles as a transient override when we
        // still see them in persisted metadata, but do not rewrite metadata
        // here. There is no reliable way to distinguish old inferred titles
        // from deliberate user titles like "Claude Code".
        return legacyAgentTitle
    }

    private static func visibleTextShowsIdleShellPrompt(_ visibleText: String) -> Bool {
        TerminalVisibleTextInspector.showsIdleShellPrompt(visibleText)
    }

    private static func titleIsEligibleForAgentInference(terminalTitle: String, terminalCWD: String) -> Bool {
        if titleLooksLikeDefaultTerminalTitle(terminalTitle) {
            return true
        }

        // Preserve compact directory titles like "clawdbot", but still allow
        // inference for raw CWD path titles ("/Users/..." or "~/...").
        guard titleLooksLikePathTitle(terminalTitle),
              let normalizedTitlePath = TerminalRuntimeRegistry.normalizedCWDValue(terminalTitle),
              let normalizedCurrentCWD = TerminalRuntimeRegistry.normalizedCWDValue(terminalCWD) else {
            return false
        }

        return canonicalCWDForComparison(normalizedTitlePath) == canonicalCWDForComparison(normalizedCurrentCWD)
    }

    private static func canonicalInferredAgentTitle(from title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        let normalized = normalizedAgentTitleCandidate(trimmed)
        guard normalized.isEmpty == false else {
            return nil
        }
        let normalizedLowercased = normalized.lowercased()

        for candidate in inferredAgentTitleCandidates {
            let candidateLowercased = candidate.lowercased()
            guard normalizedLowercased.hasPrefix(candidateLowercased) else {
                continue
            }
            let boundaryIndex = normalizedLowercased.index(
                normalizedLowercased.startIndex,
                offsetBy: candidateLowercased.count
            )
            if boundaryIndex == normalizedLowercased.endIndex {
                return candidate
            }

            let boundaryCharacter = normalizedLowercased[boundaryIndex]
            guard boundaryCharacter.isLetter == false,
                  boundaryCharacter.isNumber == false else {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func normalizedAgentTitleCandidate(_ title: String) -> String {
        var candidate = title
        while let first = candidate.first,
              first.isLetter == false,
              first.isNumber == false {
            candidate.removeFirst()
        }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func titleLooksLikeDefaultTerminalTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "terminal" {
            return true
        }

        let components = normalized.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count == 2, components[0] == "terminal" else {
            return false
        }
        return Int(components[1]) != nil
    }

    private static func titleLooksLikePathTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("file://")
    }

    private static func inferredAgentKind(terminalTitle: String, visibleText: String) -> AgentKindInference? {
        let inferredTitleFromTerminalTitle = canonicalInferredAgentTitle(from: terminalTitle)
        if inferredTitleFromTerminalTitle == "Codex" {
            return .codex
        }
        if inferredTitleFromTerminalTitle == "Claude Code" {
            return .claudeCode
        }

        if let inferredTitle = inferredAgentTitleFromVisibleTerminalText(visibleText) {
            return inferredTitle == "Codex" ? .codex : .claudeCode
        }

        guard let token = TerminalVisibleTextInspector.recentPromptCommandToken(visibleText) else {
            return nil
        }
        return agentKind(forPromptToken: token)
    }

    private static func inferredAgentPhase(visibleText: String, visibleLines: [String]) -> AgentActivityPhase {
        if visibleTextShowsWaitingForInput(visibleLines) {
            return .waitingInput
        }
        if visibleTextShowsIdleShellPrompt(visibleText) {
            return .idle
        }
        return .running
    }

    private static func visibleTextShowsWaitingForInput(_ visibleLines: [String]) -> Bool {
        guard visibleLines.isEmpty == false else { return false }
        let candidateLines = Array(visibleLines.suffix(agentTitleDetectionLineWindow))

        for line in candidateLines.reversed() {
            let lowercased = line.lowercased()
            if lowercased.contains("waiting for input")
                || lowercased.contains("waiting on user input")
                || lowercased.contains("needs your input")
                || lowercased.contains("select an option")
                || lowercased.contains("enter your choice")
                || lowercased.contains("press enter to continue")
                || lowercased.contains("press return to continue")
                || lowercased.contains("approve command")
                || lowercased.contains("approval required") {
                return true
            }

            if lowercased.contains("y/n") || lowercased.contains("[y]") || lowercased.contains("[n]") {
                return true
            }
        }

        return false
    }

    private static func workspaceActivitySubtext(from activities: [PanelActivityState], now: Date) -> String? {
        guard activities.isEmpty == false else { return nil }

        var codexCount = 0
        var claudeCount = 0
        var runningCount = 0
        var waitingInputCount = 0
        var idleCount = 0

        for activity in activities {
            switch activity.agent {
            case .codex:
                codexCount += 1
            case .claudeCode:
                claudeCount += 1
            }

            switch activity.phase {
            case .running:
                runningCount += 1
            case .waitingInput:
                waitingInputCount += 1
            case .idle:
                idleCount += 1
            }
        }

        let totalAgentCount = codexCount + claudeCount
        guard totalAgentCount > 0 else { return nil }

        let statusSegments: [String] = {
            if waitingInputCount > 0 && runningCount > 0 {
                return [
                    "\(waitingInputCount) waiting input",
                    "\(runningCount) running",
                ]
            }
            if waitingInputCount > 0 {
                return ["\(waitingInputCount) waiting input"]
            }
            if runningCount > 0 {
                return ["\(runningCount) running"]
            }
            return ["\(idleCount) idle"]
        }()
        let statusText = statusSegments.joined(separator: ", ")

        var agentSegments: [String] = []
        if claudeCount > 0 {
            agentSegments.append("\(claudeCount) \(claudeCodeActivityLabel)")
        }
        if codexCount > 0 {
            agentSegments.append("\(codexCount) Codex")
        }

        if totalAgentCount == 1,
           let mostRecentActivity = activities.max(by: { $0.updatedAt < $1.updatedAt }),
           now.timeIntervalSince(mostRecentActivity.updatedAt) <= activityCommandFreshnessInterval,
           let runningCommand = mostRecentActivity.runningCommand {
            let singleAgent = agentActivityLabel(for: mostRecentActivity.agent)
            switch mostRecentActivity.phase {
            case .running:
                return "\(runningCommand) · \(singleAgent) running"
            case .waitingInput:
                return "\(runningCommand) · \(singleAgent) waiting input"
            case .idle:
                // Idle state should fall back to aggregate status formatting.
                break
            }
        }

        return "\(agentSegments.joined(separator: ", ")) · \(statusText)"
    }

    private static func agentKind(forPromptToken token: String) -> AgentKindInference? {
        if codexPromptTokens.contains(token) {
            return .codex
        }
        if claudePromptTokens.contains(token) {
            return .claudeCode
        }
        return nil
    }

    private static func agentActivityLabel(for agent: AgentKindInference) -> String {
        switch agent {
        case .codex:
            return "1 Codex"
        case .claudeCode:
            return "1 \(claudeCodeActivityLabel)"
        }
    }

    private static func canonicalCWDForComparison(_ value: String) -> String {
        guard let normalized = TerminalRuntimeRegistry.normalizedCWDValue(value) else {
            return value
        }
        let expanded = (normalized as NSString).expandingTildeInPath
        guard expanded.isEmpty == false else {
            return normalized
        }
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static let inferredAgentTitleCandidates: [String] = ["Codex", "Claude Code"]
    private static let codexPromptTokens: Set<String> = ["codex", "cdx"]
    private static let claudePromptTokens: Set<String> = ["claude"]
    private static let activityCommandFreshnessInterval: TimeInterval = 60
    private static let claudeCodeActivityLabel = "CC"
    private static let activityRetentionInterval: TimeInterval = 240
    private static let agentTitleDetectionLineWindow = 16
}
#endif
