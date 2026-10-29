import Foundation
import RemoteProtocol

/// One agent profile with a model and an effort: what the Agent pill pins.
/// A nil model or effort leaves it to `[defaults]` or to the agent.
struct QuickEntryPreset: Hashable, Codable, Sendable {
    var agent: String
    var model: String?
    var effort: String?
}

/// What the Agent picker offers for one profile in agents.toml.
struct QuickEntryAgentProfile: Equatable {
    let id: String
    let displayName: String
    let supportsModel: Bool
    /// The efforts the provider accepts, lowest first; empty when it takes
    /// none.
    let efforts: [String]
    /// Recent/default choices first, then any provider catalog choices.
    var models: [String]
}

enum QuickEntryPickerKind: Equatable {
    case workspace
    case agent
}

enum QuickEntryCodexCatalogStatus: Equatable {
    case loading
    case unavailable
}

/// The searchable list behind a quick entry pill. Typing filters it with
/// the command palette's fuzzy scorer; ↑ ↓ move, Return chooses. The Agent
/// picker can switch to three columns for choosing the agent, model and
/// effort separately.
@MainActor
final class QuickEntryPicker: ObservableObject {
    enum Choice: Equatable {
        case workspace(UUID)
        case agent(QuickEntryPreset)
    }

    struct Row: Identifiable, Equatable {
        enum Action: Equatable {
            case workspace(UUID)
            case preset(QuickEntryPreset)
            /// Opens the columns with this agent and model chosen.
            case columns(agent: String?, model: String?)
        }

        let id: String
        var section: String?
        /// 1–5 on a Frequent row while the search is empty: the key that
        /// picks it.
        var number: Int?
        var title: String
        var detail: String?
        /// The detail is a shortcut, drawn as key caps.
        var detailIsShortcut = false
        var action: Action
        /// What the search matches: the title and anything it leaves out,
        /// such as the profile ID.
        var searchText: String
    }

    let kind: QuickEntryPickerKind
    @Published var query = "" {
        didSet {
            if query != oldValue { queryChanged() }
        }
    }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var highlightedID: Row.ID?
    /// Set while the Agent picker shows its three columns.
    @Published private(set) var columns: QuickEntryPresetColumns?
    @Published var codexCatalogStatus: QuickEntryCodexCatalogStatus?

    var onChoose: (Choice) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onRetryCodexModels: () -> Void = {}

    var showsCodexCatalogStatus: Bool {
        kind == .agent && codexCatalogStatus != nil
            && profiles.contains { $0.id == AgentKind.codex.rawValue && $0.supportsModel }
            && (columns == nil || columns?.agentID == AgentKind.codex.rawValue)
    }

    private let workspaces: [QuickEntryModel.Option]
    private(set) var profiles: [QuickEntryAgentProfile]
    private let frequent: [QuickEntryPreset]
    /// The preset rows: the pinned preset under "Current" when it is not a
    /// Frequent one, so the picker opens on it, then the Frequent presets.
    private let listedPresets: [(preset: QuickEntryPreset, section: String)]
    /// The pill's value when the picker opened; nil while none is chosen.
    private let currentWorkspaceID: UUID?
    private let currentPreset: QuickEntryPreset?
    /// Presets whose effort was changed with ← →, by row.
    private var adjustedPresets: [Row.ID: QuickEntryPreset] = [:]

    init(workspaces: [QuickEntryModel.Option], current: UUID?) {
        kind = .workspace
        self.workspaces = workspaces
        profiles = []
        frequent = []
        listedPresets = []
        currentWorkspaceID = current
        currentPreset = nil
        rebuildRows(highlightingCurrent: true)
    }

    init(profiles: [QuickEntryAgentProfile], frequent: [QuickEntryPreset], current: QuickEntryPreset?) {
        kind = .agent
        workspaces = []
        self.profiles = profiles
        let offered = { (preset: QuickEntryPreset) in profiles.contains { $0.id == preset.agent } }
        self.frequent = frequent.filter(offered)
        var listed = self.frequent.map { (preset: $0, section: "Frequent") }
        if let current, offered(current), self.frequent.contains(current) == false {
            listed.insert((current, "Current"), at: 0)
        }
        listedPresets = listed
        currentWorkspaceID = nil
        currentPreset = current
        rebuildRows(highlightingCurrent: true)
    }

    var highlightedRow: Row? {
        rows.first { $0.id == highlightedID }
    }

    /// Catalog results add choices without changing what the user has typed
    /// or selected. IDs and model tokens stay stable even when rows move.
    func updateProfiles(_ profiles: [QuickEntryAgentProfile]) {
        guard kind == .agent else { return }
        self.profiles = profiles
        if columns != nil {
            columns?.profiles = profiles
        } else {
            let previous = highlightedID
            rebuildRows(highlightingCurrent: false)
            if let previous, rows.contains(where: { $0.id == previous }) {
                highlightedID = previous
            }
        }
    }

    // MARK: - Keys

    func move(_ delta: Int) {
        if columns != nil {
            columns?.move(delta)
            return
        }
        guard rows.isEmpty == false else { return }
        let index = rows.firstIndex { $0.id == highlightedID } ?? -1
        highlightedID = rows[min(max(index + delta, 0), rows.count - 1)].id
    }

    /// ← →: changes the effort of a highlighted Frequent row. Returns false
    /// on any other row, so the key moves the caret instead.
    func adjustEffort(_ delta: Int) -> Bool {
        guard columns == nil,
              let row = highlightedRow,
              case .preset(let preset) = row.action,
              let profile = profile(preset.agent),
              profile.efforts.isEmpty == false else {
            return false
        }
        // Default comes before the lowest effort.
        let steps: [String?] = [nil] + profile.efforts
        let index = steps.firstIndex(of: preset.effort) ?? 0
        let next = steps[min(max(index + delta, 0), steps.count - 1)]
        guard next != preset.effort else { return true }
        var adjusted = preset
        adjusted.effort = next
        adjustedPresets[row.id] = adjusted
        rebuildRows(highlightingCurrent: false)
        return true
    }

    /// 1–5 while the search is empty: picks that Frequent preset. Returns
    /// false otherwise, so the digit goes to the search.
    func chooseFrequent(number: Int) -> Bool {
        guard columns == nil, let row = rows.first(where: { $0.number == number }) else { return false }
        highlightedID = row.id
        perform(row)
        return true
    }

    /// Tab moves between the columns. In the list there is nowhere to go,
    /// and the key is used up so focus stays in the search.
    func tab(_ delta: Int) {
        guard columns != nil else { return }
        columns?.focusNext(delta)
        query = ""
    }

    func submit() {
        if let columns {
            // A search with no match leaves the old choice, which the user
            // cannot see in the filtered column.
            guard columns.hasMatch else { return }
            onChoose(.agent(columns.preset))
            return
        }
        guard let row = highlightedRow else { return }
        perform(row)
    }

    func cancel() {
        onClose()
    }

    /// A click on a row.
    func choose(rowID: Row.ID) {
        guard let row = rows.first(where: { $0.id == rowID }) else { return }
        highlightedID = rowID
        perform(row)
    }

    /// A click on a cell in the columns.
    func select(_ cell: QuickEntryPresetColumns.Cell, in column: QuickEntryPresetColumns.Column) {
        columns?.select(cell, in: column)
        query = ""
    }

    /// ⌘→, or "Choose agent, model, effort…".
    func openColumns(agent: String? = nil, model: String? = nil) {
        guard kind == .agent, columns == nil else { return }
        var start: QuickEntryPreset
        if let preset = currentPreset, profile(preset.agent) != nil {
            start = preset
        } else if let first = frequent.first ?? profiles.first.map({ QuickEntryPreset(agent: $0.id) }) {
            start = first
        } else {
            return
        }
        if let agent, agent != start.agent {
            start = QuickEntryPreset(agent: agent)
        }
        if let model {
            start.model = model
        }
        var focus = QuickEntryPresetColumns.Column.agent
        if model != nil {
            focus = .effort
        } else if agent != nil {
            focus = .model
        }
        query = ""
        columns = QuickEntryPresetColumns(profiles: profiles, preset: start, focus: focus)
    }

    // MARK: - Rows

    private func perform(_ row: Row) {
        switch row.action {
        case .workspace(let workspaceID):
            onChoose(.workspace(workspaceID))
        case .preset(let preset):
            onChoose(.agent(preset))
        case .columns(let agent, let model):
            openColumns(agent: agent, model: model)
        }
    }

    private func queryChanged() {
        if columns != nil {
            columns?.setQuery(query)
        } else {
            rebuildRows(highlightingCurrent: false)
        }
    }

    private func rebuildRows(highlightingCurrent: Bool) {
        let previous = highlightedID
        switch kind {
        case .workspace:
            rows = Self.workspaceRows(workspaces, query: query)
        case .agent:
            rows = Self.agentRows(
                profiles: profiles,
                presets: listedPresets.map { listed in
                    (listed.preset, adjustedPresets[Self.presetRowID(listed.preset)] ?? listed.preset, listed.section)
                },
                query: query
            )
            if query.isEmpty {
                var number = 0
                for index in rows.indices where rows[index].section == "Frequent" {
                    number += 1
                    rows[index].number = number
                }
            }
        }
        if highlightingCurrent, let id = currentRowID, rows.contains(where: { $0.id == id }) {
            highlightedID = id
        } else if query.isEmpty, let previous, rows.contains(where: { $0.id == previous }) {
            // ← → rebuild the rows; the highlight stays on its row.
            highlightedID = previous
        } else {
            highlightedID = rows.first?.id
        }
    }

    /// The row for the pill's value, highlighted when the picker opens.
    /// With nothing chosen yet, the picker starts on its first row.
    private var currentRowID: Row.ID? {
        switch kind {
        case .workspace:
            return currentWorkspaceID.map { "workspace:\($0.uuidString)" }
        case .agent:
            return currentPreset.map(Self.presetRowID)
        }
    }

    private func profile(_ id: String) -> QuickEntryAgentProfile? {
        profiles.first { $0.id == id }
    }

    static func presetRowID(_ preset: QuickEntryPreset) -> Row.ID {
        "preset:\(preset.agent)|\(preset.model ?? "")|\(preset.effort ?? "")"
    }

    /// The open workspaces.
    static func workspaceRows(_ workspaces: [QuickEntryModel.Option], query: String) -> [Row] {
        let open = workspaces.compactMap { option -> Row? in
            guard let id = UUID(uuidString: option.id) else { return nil }
            return Row(
                id: "workspace:\(option.id)",
                section: "Open workspaces",
                title: option.title,
                action: .workspace(id),
                searchText: option.title
            )
        }
        return ranked(open, query: query)
    }

    /// The preset rows and the columns. A search also lists every
    /// agent and agent + model pair, after the presets. Each preset comes
    /// with its effort as adjusted with ← →, and its section.
    static func agentRows(
        profiles: [QuickEntryAgentProfile],
        presets: [(original: QuickEntryPreset, shown: QuickEntryPreset, section: String)],
        query: String
    ) -> [Row] {
        let names = Dictionary(profiles.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let presetRows = presets.map { listed -> Row in
            let (original, shown, section) = listed
            let name = names[shown.agent] ?? shown.agent
            let title = [name, shown.model].compactMap { $0 }.joined(separator: " · ")
            let acceptsEffort = profiles.first { $0.id == shown.agent }?.efforts.isEmpty == false
            return Row(
                id: presetRowID(original),
                section: section,
                title: title,
                detail: acceptsEffort ? (shown.effort ?? "default") : nil,
                action: .preset(shown),
                searchText: "\(title) \(shown.effort ?? "") \(shown.agent)"
            )
        }
        let other = [
            Row(
                id: "columns",
                section: "Other",
                title: "Choose agent, model, effort…",
                detail: "⌘→",
                detailIsShortcut: true,
                action: .columns(agent: nil, model: nil),
                searchText: "Choose agent model effort custom"
            ),
        ]
        guard query.normalizedPaletteQuery.isEmpty == false else {
            return presetRows + other
        }

        var pairs: [Row] = []
        for profile in profiles {
            let effortHint = profile.efforts.isEmpty ? nil : "pick effort →"
            pairs.append(Row(
                id: "agent:\(profile.id)",
                section: "Models",
                title: profile.displayName,
                detail: profile.supportsModel ? "pick model →" : effortHint,
                action: profile.supportsModel || profile.efforts.isEmpty == false
                    ? .columns(agent: profile.id, model: nil)
                    : .preset(QuickEntryPreset(agent: profile.id)),
                searchText: "\(profile.displayName) \(profile.id)"
            ))
            for model in profile.models where profile.supportsModel {
                pairs.append(Row(
                    id: "model:\(profile.id)|\(model)",
                    section: "Models",
                    title: "\(profile.displayName) · \(model)",
                    detail: effortHint,
                    action: profile.efforts.isEmpty
                        ? .preset(QuickEntryPreset(agent: profile.id, model: model))
                        : .columns(agent: profile.id, model: model),
                    searchText: "\(profile.displayName) \(model) \(profile.id)"
                ))
            }
        }
        // The columns row follows the pairs, unless its title starts with
        // the search: a word such as "choose" can also match inside a
        // profile name.
        let normalized = query.normalizedPaletteQuery
        let otherMatches = ranked(other, query: query)
        let leading = otherMatches.filter { $0.title.lowercased().hasPrefix(normalized) }
        return leading
            + ranked(presetRows, query: query)
            + ranked(pairs, query: query)
            + otherMatches.filter { row in leading.contains { $0.id == row.id } == false }
    }

    /// The rows the query matches, best first; ties keep their order.
    static func ranked(_ rows: [Row], query: String) -> [Row] {
        guard query.normalizedPaletteQuery.isEmpty == false else { return rows }
        return rows.enumerated()
            .compactMap { index, row in QuickEntrySearch.score(query, in: row.searchText).map { (index, $0, row) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map(\.2)
    }
}

/// The Agent picker's three columns: Agent, Model and Effort. Typing
/// filters the focused column; Tab moves between them. Model is hidden for
/// a profile that takes no model, and Effort for one that takes no effort.
struct QuickEntryPresetColumns: Equatable {
    enum Column: CaseIterable {
        case agent
        case model
        case effort

        var title: String {
            switch self {
            case .agent: "Agent"
            case .model: "Model"
            case .effort: "Effort"
            }
        }
    }

    struct Cell: Identifiable, Equatable {
        enum Value: Equatable {
            case agent(String)
            /// nil is Default.
            case model(String?)
            case effort(String?)
            /// What the user typed in the Model column.
            case typedModel(String)
            /// A note that cannot be chosen, such as "Type a model…".
            case note
        }

        let id: String
        let title: String
        let value: Value
        var isMuted = false

        var isSelectable: Bool { value != .note }
    }

    var profiles: [QuickEntryAgentProfile]
    private(set) var agentID: String
    private(set) var model: String?
    private(set) var effort: String?
    private(set) var focused: Column
    private(set) var query = ""

    init?(profiles: [QuickEntryAgentProfile], preset: QuickEntryPreset, focus: Column) {
        guard let profile = profiles.first(where: { $0.id == preset.agent }) ?? profiles.first else { return nil }
        self.profiles = profiles
        agentID = profile.id
        model = profile.supportsModel ? preset.model : nil
        effort = profile.efforts.contains { $0 == preset.effort } ? preset.effort : nil
        focused = focus
        if visibleColumns.contains(focus) == false {
            focused = visibleColumns.last ?? .agent
        }
    }

    var profile: QuickEntryAgentProfile {
        profiles.first { $0.id == agentID } ?? profiles[0]
    }

    var visibleColumns: [Column] {
        [.agent]
            + (profile.supportsModel ? [.model] : [])
            + (profile.efforts.isEmpty ? [] : [.effort])
    }

    /// What Return chooses.
    var preset: QuickEntryPreset {
        QuickEntryPreset(
            agent: agentID,
            model: profile.supportsModel ? model : nil,
            effort: profile.efforts.isEmpty ? nil : effort
        )
    }

    func isSelected(_ cell: Cell) -> Bool {
        switch cell.value {
        case .agent(let id): id == agentID
        case .model(let value): value == model
        case .effort(let value): value == effort
        case .typedModel(let value): value == model
        case .note: false
        }
    }

    /// The column's cells, filtered by the query when it has focus.
    func cells(in column: Column) -> [Cell] {
        let searching = column == focused && query.normalizedPaletteQuery.isEmpty == false
        switch column {
        case .agent:
            let cells = profiles.map { Cell(id: "agent:\($0.id)", title: $0.displayName, value: .agent($0.id)) }
            return searching ? Self.filtered(cells, query: query, searchText: { cell in
                guard case .agent(let id) = cell.value else { return cell.title }
                return "\(cell.title) \(id)"
            }) : cells
        case .model:
            var models = profile.models
            if let model, models.contains(model) == false {
                models.insert(model, at: 0)
            }
            var cells = models.map { Cell(id: "model:\($0)", title: $0, value: .model($0)) }
            cells.append(Cell(id: "model:default", title: "Default", value: .model(nil), isMuted: true))
            guard searching else {
                cells.append(Cell(id: "model:note", title: "Type a model…", value: .note, isMuted: true))
                return cells
            }
            var matches = Self.filtered(cells, query: query, searchText: \.title)
            let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if matches.contains(where: { $0.title == typed }) == false {
                if RemoteSessionStartPolicy.isValidSelectionValue(typed, maximumLength: RemoteSessionStartPolicy.maximumModelLength) {
                    matches.append(Cell(id: "model:typed", title: "Use “\(typed)”", value: .typedModel(typed)))
                } else {
                    matches.append(Cell(id: "model:note", title: "A model is one word", value: .note, isMuted: true))
                }
            }
            return matches
        case .effort:
            var cells = profile.efforts.map { Cell(id: "effort:\($0)", title: $0, value: .effort($0)) }
            cells.append(Cell(id: "effort:default", title: "Default", value: .effort(nil), isMuted: true))
            return searching ? Self.filtered(cells, query: query, searchText: \.title) : cells
        }
    }

    /// False while the focused column's search matches nothing it can
    /// choose; Return then does nothing.
    var hasMatch: Bool {
        query.normalizedPaletteQuery.isEmpty || cells(in: focused).contains(where: \.isSelectable)
    }

    /// Filters the focused column and chooses its best match.
    mutating func setQuery(_ query: String) {
        self.query = query
        guard query.normalizedPaletteQuery.isEmpty == false,
              let first = cells(in: focused).first(where: \.isSelectable) else { return }
        apply(first)
    }

    mutating func move(_ delta: Int) {
        let cells = cells(in: focused).filter(\.isSelectable)
        guard cells.isEmpty == false else { return }
        let index = cells.firstIndex(where: { isSelected($0) }) ?? (delta > 0 ? -1 : cells.count)
        apply(cells[min(max(index + delta, 0), cells.count - 1)])
    }

    mutating func focusNext(_ delta: Int) {
        let visible = visibleColumns
        let index = visible.firstIndex(of: focused) ?? 0
        focused = visible[(index + delta + visible.count) % visible.count]
        query = ""
    }

    mutating func select(_ cell: Cell, in column: Column) {
        guard cell.isSelectable, visibleColumns.contains(column) else { return }
        focused = column
        query = ""
        apply(cell)
    }

    private mutating func apply(_ cell: Cell) {
        switch cell.value {
        case .agent(let id):
            guard id != agentID, let next = profiles.first(where: { $0.id == id }) else { return }
            agentID = id
            // A model or effort the new agent does not list goes back to
            // Default.
            if let model, next.supportsModel == false || next.models.contains(model) == false {
                self.model = nil
            }
            if let effort, next.efforts.contains(effort) == false {
                self.effort = nil
            }
        case .model(let value):
            model = value
        case .typedModel(let value):
            model = value
        case .effort(let value):
            effort = value
        case .note:
            break
        }
    }

    private static func filtered(_ cells: [Cell], query: String, searchText: (Cell) -> String) -> [Cell] {
        cells.enumerated()
            .compactMap { index, cell in QuickEntrySearch.score(query, in: searchText(cell)).map { (index, $0, cell) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map(\.2)
    }
}

/// Search with the command palette's fuzzy scorer. Every word of the query
/// must match; the score is their sum.
enum QuickEntrySearch {
    static func score(_ query: String, in candidate: String) -> Int? {
        let terms = query.normalizedPaletteSearchTerms
        guard terms.isEmpty == false else { return 0 }
        let normalized = candidate.normalizedPaletteQuery
        var total = 0
        for term in terms {
            guard let match = FuzzyScorer.matchNormalized(query: term, candidate: normalized) else { return nil }
            total += match.score
        }
        return total
    }

    /// The offsets of the characters in `text` that the query's words
    /// match, found the way the scorer finds them, for highlighting.
    static func matchedOffsets(_ query: String, in text: String) -> Set<Int> {
        let characters = Array(text.lowercased())
        var offsets: Set<Int> = []
        for term in query.normalizedPaletteSearchTerms {
            var start = 0
            var found: [Int] = []
            for character in term {
                guard start < characters.count,
                      let index = characters[start...].firstIndex(of: character) else {
                    found = []
                    break
                }
                found.append(index)
                start = index + 1
            }
            offsets.formUnion(found)
        }
        return offsets
    }
}
