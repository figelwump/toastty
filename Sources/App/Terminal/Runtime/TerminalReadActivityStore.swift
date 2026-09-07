import Combine
import Foundation

/// One session that has read a terminal panel's text through automation.
struct TerminalReadActivityReader: Equatable, Identifiable, Sendable {
    let sessionID: String
    /// User-facing label for the reader, e.g. "Claude Code" or a custom
    /// session title. Resolved at record time so the label survives the
    /// reader session ending.
    var label: String
    var readCount: Int
    var lastReadAt: Date

    var id: String { sessionID }
}

/// Per-panel observable record of which other sessions have read this panel.
/// Mirrors `TerminalLiveTitleModel`: only the model is observable so header
/// invalidation stays panel-scoped.
@MainActor
final class TerminalReadActivityModel: ObservableObject {
    let panelID: UUID
    /// Readers ordered by most recent read first.
    @Published private(set) var readers: [TerminalReadActivityReader] = []
    /// Monotonic count of reads across all readers. Views key their flash
    /// animation on this changing, so no timer lives in the store.
    @Published private(set) var totalReadCount: Int = 0

    init(panelID: UUID) {
        self.panelID = panelID
    }

    var hasReaders: Bool { readers.isEmpty == false }
    var mostRecentReader: TerminalReadActivityReader? { readers.first }

    func recordRead(sessionID: String, label: String, at date: Date) {
        var next = readers
        if let index = next.firstIndex(where: { $0.sessionID == sessionID }) {
            var reader = next.remove(at: index)
            reader.label = label
            reader.readCount += 1
            reader.lastReadAt = date
            next.insert(reader, at: 0)
        } else {
            next.insert(
                TerminalReadActivityReader(sessionID: sessionID, label: label, readCount: 1, lastReadAt: date),
                at: 0
            )
        }
        readers = next
        totalReadCount += 1
    }

    /// Drops readers whose sessions are no longer live. Returns true when
    /// anything changed.
    @discardableResult
    func retainReaders(where isLive: (String) -> Bool) -> Bool {
        let next = readers.filter { isLive($0.sessionID) }
        guard next != readers else { return false }
        readers = next
        return true
    }
}

/// Registry-owned store of read activity for every live terminal panel.
@MainActor
final class TerminalReadActivityStore {
    /// Label used when a read arrives without a resolvable caller session.
    static let unknownReaderLabel = "automation client"
    static let unknownReaderSessionID = "toastty.unknown-automation-client"

    private var modelsByPanelID: [UUID: TerminalReadActivityModel] = [:]

    func model(for panelID: UUID) -> TerminalReadActivityModel {
        if let model = modelsByPanelID[panelID] {
            return model
        }
        let model = TerminalReadActivityModel(panelID: panelID)
        modelsByPanelID[panelID] = model
        return model
    }

    func existingModel(for panelID: UUID) -> TerminalReadActivityModel? {
        modelsByPanelID[panelID]
    }

    func recordRead(panelID: UUID, sessionID: String?, label: String?, at date: Date = Date()) {
        model(for: panelID).recordRead(
            sessionID: sessionID ?? Self.unknownReaderSessionID,
            label: label ?? Self.unknownReaderLabel,
            at: date
        )
    }

    /// Removes readers whose sessions have ended. The unknown-client reader
    /// is never pruned by this path because no session owns it.
    func retainReaders(liveSessionIDs: Set<String>) {
        for model in modelsByPanelID.values {
            model.retainReaders { sessionID in
                sessionID == Self.unknownReaderSessionID || liveSessionIDs.contains(sessionID)
            }
        }
    }

    func synchronizeLivePanels(_ livePanelIDs: Set<UUID>) {
        modelsByPanelID = modelsByPanelID.filter { panelID, _ in
            livePanelIDs.contains(panelID)
        }
    }

    func remove(panelID: UUID) {
        modelsByPanelID.removeValue(forKey: panelID)
    }
}
