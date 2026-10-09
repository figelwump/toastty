import CoreState
import Foundation
import RemoteProtocol

/// Transient terminal state, deliberately outside managed sessions and remote sync.
struct TerminalProgramStatusRuntime {
    var recordsByPanel: [UUID: TerminalProgramStatusRecords] = [:]
    var fallbackSessionIDs: Set<String> = []
    var panelsWithPrompt: Set<UUID> = []
    var panelsAwaitingPrompt: Set<UUID> = []

    mutating func apply(_ event: TerminalProgramStatusEvent, panelID: UUID, owner: SessionRecord?) {
        switch event {
        case .prompt:
            panelsWithPrompt.insert(panelID)
            panelsAwaitingPrompt.remove(panelID)
        case .reset, .exit:
            panelsAwaitingPrompt.remove(panelID)
        case .report:
            guard !panelsAwaitingPrompt.contains(panelID) else { return }
            if let owner, !fallbackSessionIDs.contains(owner.sessionID) { return }
        }
        var records = recordsByPanel[panelID] ?? .init()
        records.apply(event)
        recordsByPanel[panelID] = records.records.isEmpty ? nil : records
    }

    mutating func start(panelID: UUID, sessionID: String) {
        recordsByPanel.removeValue(forKey: panelID)
        panelsAwaitingPrompt.remove(panelID)
        fallbackSessionIDs.remove(sessionID)
    }

    mutating func stop(_ record: SessionRecord) {
        let wasFallback = fallbackSessionIDs.remove(record.sessionID) != nil
        if wasFallback {
            var records = recordsByPanel[record.panelID] ?? .init()
            records.apply(.exit)
            recordsByPanel[record.panelID] = records.records.isEmpty ? nil : records
        }
        if record.agent != .processWatch, panelsWithPrompt.contains(record.panelID) {
            panelsAwaitingPrompt.insert(record.panelID)
        }
    }

    mutating func claim(_ record: SessionRecord) {
        fallbackSessionIDs.remove(record.sessionID)
        recordsByPanel.removeValue(forKey: record.panelID)
    }

    mutating func synchronize(livePanelIDs: Set<UUID>, activeSessionIDs: Set<String>) {
        recordsByPanel = recordsByPanel.filter { livePanelIDs.contains($0.key) }
        fallbackSessionIDs.formIntersection(activeSessionIDs)
        panelsWithPrompt.formIntersection(livePanelIDs)
        panelsAwaitingPrompt.formIntersection(livePanelIDs)
    }
}

struct SidebarProgramStatusRow: Identifiable, Equatable {
    let panelID: UUID
    let terminalTitle: String
    let presentation: TerminalProgramStatusPresentation
    let fallbackAgent: AgentKind?
    var id: UUID { panelID }

    private var knownAgent: AgentKind? {
        switch presentation.app {
        case "claude-code", "claude": .claude
        case "codex": .codex
        case "cursor", "cursor-agent": .cursor
        case "grok": .grok
        case "mimocode": .mimocode
        case "opencode": .opencode
        case "pi": .pi
        case nil: fallbackAgent
        default: nil
        }
    }

    var isAgent: Bool { knownAgent != nil }
    var title: String {
        clean(presentation.rootTitle) ?? clean(presentation.record.title)
            ?? knownAgent?.displayName ?? clean(presentation.app) ?? "Program"
    }
    var summary: String? {
        let message = clean(presentation.record.message)
        if let id = presentation.record.id, !id.isEmpty,
           let childTitle = clean(presentation.record.title), childTitle != title {
            return message.map { childTitle + ": " + $0 } ?? childTitle
        }
        return message
    }
    var status: SessionStatus {
        let kind: SessionStatusKind = switch presentation.record.state {
        case .idle, .clear: .idle
        case .working: .working
        case .blocked: .needsApproval
        case .done: .ready
        case .error: .error
        }
        return .init(kind: kind, summary: summary ?? "")
    }
    var badge: String? {
        guard presentation.record.state == .blocked else { return nil }
        switch presentation.record.kind {
        case .permission: return "approval"
        case .question: return "input"
        case .auth: return "login"
        case nil: return "blocked"
        }
    }
    var terminalLabel: String { clean(terminalTitle) ?? "Terminal" }
    var accessibilityLabel: String {
        [title, badge ?? presentation.record.state.rawValue, summary,
         presentation.record.progress.map { "\($0) percent" }, "Terminal: \(terminalLabel)"]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        // Terminal text is untrusted. Keep it plain and remove invisible
        // direction/format controls that can disguise names in the sidebar.
        let value = String(String.UnicodeScalarView(text.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            // ZWJ and ZWNJ are part of visible emoji and script shaping.
            if scalar == "\u{200C}" || scalar == "\u{200D}" { return scalar }
            return CharacterSet.controlCharacters.contains(scalar) ? nil : scalar
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

extension SessionRuntimeStore {
    func handleProgramStatusEvent(_ event: TerminalProgramStatusEvent, panelID: UUID) {
        let previousRecords = programStatusRuntime.recordsByPanel
        programStatusRuntime.apply(event, panelID: panelID, owner: sessionRegistry.activeSession(for: panelID))
        scheduleProgramStatusPublication(ifRecordsChangedFrom: previousRecords)
    }

    func allowProgramStatusFallback(sessionID: String) {
        guard let owner = sessionRegistry.activeSession(sessionID: sessionID), owner.agent != .processWatch else { return }
        if programStatusRuntime.fallbackSessionIDs.insert(sessionID).inserted,
           programStatusRuntime.recordsByPanel[owner.panelID] != nil {
            scheduleProgramStatusPublication()
        }
    }

    func programStatusRows(in workspace: WorkspaceState) -> [SidebarProgramStatusRow] {
        let panelIDs = workspace.tabIDs.flatMap { tabID in
            workspace.tabsByID[tabID]?.layoutTree.allSlotInfos.map(\.panelID) ?? []
        }
        return panelIDs.compactMap { panelID in
            guard let presentation = programStatusRuntime.recordsByPanel[panelID]?.presentation,
                  case .terminal(let terminal) = workspace.allPanelsByID[panelID] else { return nil }
            let owner = sessionRegistry.activeSession(for: panelID)
            if let owner, !programStatusRuntime.fallbackSessionIDs.contains(owner.sessionID) { return nil }
            return .init(panelID: panelID, terminalTitle: terminal.title,
                         presentation: presentation, fallbackAgent: owner?.agent)
        }
    }

    func scheduleProgramStatusPublication(ifRecordsChangedFrom previousRecords: [UUID: TerminalProgramStatusRecords]) {
        if programStatusRuntime.recordsByPanel != previousRecords {
            scheduleProgramStatusPublication()
        }
    }

    func scheduleProgramStatusPublication() {
        guard programStatusPublicationTask == nil else { return }
        programStatusPublicationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            self.programStatusPublicationTask = nil
            self.programStatusRevision &+= 1
        }
    }
}
