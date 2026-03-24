#if TOASTTY_HAS_GHOSTTY_KIT
import CoreState
import Foundation

@MainActor
final class TerminalActivityInferenceService {
    private struct PanelBusyState {
        var workspaceID: UUID
        var updatedAt: Date
    }

    private enum AgentKindInference {
        case codex
        case claudeCode
    }

    private let readVisibleText: (UUID) -> String?
    private var sessionLifecycleTracker: (any TerminalSessionLifecycleTracking)?
    // Keep inferred agent labels out of persisted terminal metadata. The pane
    // header reads from this transient override and falls back to terminal
    // title/CWD metadata when no override is present.
    private(set) var panelDisplayTitleOverrideByID: [UUID: String] = [:]
    // Workspace subtitles track generic terminal busy state, regardless of
    // whether the foreground process is an agent, shell command, or TUI.
    private var busyPanelStateByPanelID: [UUID: PanelBusyState] = [:]
    private(set) var workspaceActivitySubtextByID: [UUID: String] = [:]

    init(
        readVisibleText: @escaping (UUID) -> String?,
        sessionLifecycleTracker: (any TerminalSessionLifecycleTracking)? = nil
    ) {
        self.readVisibleText = readVisibleText
        self.sessionLifecycleTracker = sessionLifecycleTracker
    }

    func bind(sessionLifecycleTracker: (any TerminalSessionLifecycleTracking)?) {
        self.sessionLifecycleTracker = sessionLifecycleTracker
    }

    func invalidate(panelID: UUID) {
        panelDisplayTitleOverrideByID.removeValue(forKey: panelID)
        busyPanelStateByPanelID.removeValue(forKey: panelID)
    }

    func synchronizeLivePanels(_ livePanelIDs: Set<UUID>, liveWorkspaceIDs: Set<UUID>) {
        panelDisplayTitleOverrideByID = panelDisplayTitleOverrideByID.filter { panelID, _ in
            livePanelIDs.contains(panelID)
        }
        busyPanelStateByPanelID = busyPanelStateByPanelID.filter { panelID, _ in
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
        pruneStaleBusyPanels(now: now)
        workspaceActivitySubtextByID = nextWorkspaceActivitySubtext(
            liveWorkspaceIDs: liveWorkspaceIDs,
            now: now
        )
    }

    func handleCommandFinished(panelID: UUID, liveWorkspaceIDs: Set<UUID>) -> Bool {
        var didChange = busyPanelStateByPanelID.removeValue(forKey: panelID) != nil

        if let visibleText = readVisibleText(panelID),
           Self.visibleTextShowsIdleShellPrompt(visibleText),
           panelDisplayTitleOverrideByID.removeValue(forKey: panelID) != nil {
            didChange = true
        }

        if didChange {
            refreshWorkspaceActivitySubtext(liveWorkspaceIDs: liveWorkspaceIDs)
        }
        return didChange
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
            refreshPanelBusyStateFromVisibleTextIfNeeded(
                panelID: panelID,
                workspaceID: workspaceID,
                state: state,
                now: now
            )
        }

        for (panelID, workspaceID) in backgroundPanelWorkspaceIDs {
            refreshPanelBusyStateFromVisibleTextIfNeeded(
                panelID: panelID,
                workspaceID: workspaceID,
                state: state,
                now: now
            )
        }

        pruneStaleBusyPanels(now: now)
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

        if let promptToken = TerminalVisibleTextInspector.recentPromptCommandToken(visibleText),
           Self.agentKind(forPromptToken: promptToken) == nil {
            panelDisplayTitleOverrideByID.removeValue(forKey: panelID)
            return
        }

        if let inferredAgentTitle = Self.inferredAgentDisplayTitle(
            visibleText: visibleText,
            legacyAgentTitle: legacyAgentTitle
        ) {
            if panelDisplayTitleOverrideByID[panelID] != inferredAgentTitle {
                panelDisplayTitleOverrideByID[panelID] = inferredAgentTitle
                ToasttyLog.debug(
                    "Updated transient inferred agent display title from visible terminal text",
                    category: .terminal,
                    metadata: [
                        "workspace_id": workspaceID.uuidString,
                        "panel_id": panelID.uuidString,
                        "inferred_title": inferredAgentTitle,
                    ]
                )
            }
            return
        }

        // Visible-text inspection can miss banner text transiently while the
        // agent is still streaming output. Keep any existing override until the
        // shell returns to an idle prompt or a new non-agent prompt command
        // becomes visible.
    }

    private func refreshPanelBusyStateFromVisibleTextIfNeeded(
        panelID: UUID,
        workspaceID: UUID,
        state: AppState,
        now: Date
    ) {
        guard let workspace = state.workspacesByID[workspaceID],
              let panelState = workspace.panels[panelID],
              case .terminal = panelState else {
            busyPanelStateByPanelID.removeValue(forKey: panelID)
            return
        }

        guard let visibleText = readVisibleText(panelID) else {
            return
        }

        let appearsBusy = TerminalVisibleTextInspector.appearsBusy(visibleText)
        if appearsBusy {
            busyPanelStateByPanelID[panelID] = PanelBusyState(
                workspaceID: workspaceID,
                updatedAt: now
            )
        } else {
            busyPanelStateByPanelID.removeValue(forKey: panelID)
        }

        let recentPromptCommandToken = TerminalVisibleTextInspector.recentPromptCommandToken(visibleText)
        let showsIdlePrompt = Self.visibleTextShowsIdleShellPrompt(visibleText)
        if showsIdlePrompt {
            ToasttyLog.debug(
                "Visible terminal text looked like an idle shell prompt; attempting prompt-based session stop",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "appears_busy": appearsBusy ? "true" : "false",
                    "recent_prompt_command_token": recentPromptCommandToken ?? "none",
                ]
            )
            _ = sessionLifecycleTracker?.stopSessionForPanelIfOlderThan(
                panelID: panelID,
                minimumRuntime: Self.sessionAutoStopShellPromptGraceInterval,
                reason: .idleShellPrompt(
                    recentPromptCommandToken: recentPromptCommandToken,
                    appearsBusy: appearsBusy
                ),
                at: now
            )
        }
    }

    private func pruneStaleBusyPanels(now: Date) {
        busyPanelStateByPanelID = busyPanelStateByPanelID.filter { _, busyState in
            now.timeIntervalSince(busyState.updatedAt) <= Self.activityRetentionInterval
        }
    }

    private func updateWorkspaceActivitySubtext(state: AppState, now: Date) {
        pruneStaleBusyPanels(now: now)
        workspaceActivitySubtextByID = nextWorkspaceActivitySubtext(
            liveWorkspaceIDs: Set(state.workspacesByID.keys),
            now: now
        )
    }

    private func nextWorkspaceActivitySubtext(
        liveWorkspaceIDs: Set<UUID>,
        now: Date
    ) -> [UUID: String] {
        var busyCountByWorkspaceID: [UUID: Int] = [:]
        for busyState in busyPanelStateByPanelID.values {
            guard liveWorkspaceIDs.contains(busyState.workspaceID) else { continue }
            guard now.timeIntervalSince(busyState.updatedAt) <= Self.activityRetentionInterval else { continue }
            busyCountByWorkspaceID[busyState.workspaceID, default: 0] += 1
        }

        var nextSubtextByWorkspaceID: [UUID: String] = [:]
        for (workspaceID, busyCount) in busyCountByWorkspaceID {
            guard let subtext = Self.workspaceActivitySubtext(forBusyPanelCount: busyCount) else { continue }
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

    private static func workspaceActivitySubtext(forBusyPanelCount busyPanelCount: Int) -> String? {
        guard busyPanelCount > 0 else { return nil }
        return busyPanelCount == 1 ? "1 busy" : "\(busyPanelCount) busy"
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
    private static let activityRetentionInterval: TimeInterval = 240
    private static let agentTitleDetectionLineWindow = 16
    private static let sessionAutoStopShellPromptGraceInterval: TimeInterval = 2
}
#endif
