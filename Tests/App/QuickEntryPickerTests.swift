import AppKit
import Foundation
import Testing
@testable import ToasttyApp

/// The Workspace and Agent pickers' lists, search, effort stepping and
/// columns. The keys that reach them are covered in `QuickEntryTests`.
@MainActor
struct QuickEntryPickerTests {
    static let claude = QuickEntryAgentProfile(
        id: "claude", displayName: "Claude Code", supportsModel: true,
        efforts: ["low", "medium", "high", "xhigh", "max"], models: ["claude-opus-5-5", "claude-sonnet-5-5"]
    )
    static let codex = QuickEntryAgentProfile(
        id: "codex", displayName: "Codex", supportsModel: true,
        efforts: ["low", "medium", "high", "xhigh"], models: ["gpt-6.1-sol", "gpt-6-astra"]
    )
    static let cursor = QuickEntryAgentProfile(
        id: "cursor", displayName: "Cursor", supportsModel: true, efforts: [], models: ["composer-2"]
    )
    static let shipper = QuickEntryAgentProfile(
        id: "shipper", displayName: "Shipper (Codex, release authority)", supportsModel: false, efforts: [], models: []
    )
    static let profiles = [claude, codex, cursor, shipper]
    static let opusHigh = QuickEntryPreset(agent: "claude", model: "claude-opus-5-5", effort: "high")

    private func agentPicker(
        frequent: [QuickEntryPreset] = [opusHigh],
        current: QuickEntryPreset? = nil
    ) -> (QuickEntryPicker, Box<[QuickEntryPicker.Choice]>) {
        let picker = QuickEntryPicker(profiles: Self.profiles, frequent: frequent, current: current)
        let choices = Box<[QuickEntryPicker.Choice]>([])
        picker.onChoose = { choices.value.append($0) }
        return (picker, choices)
    }

    final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    // MARK: - Workspace

    @Test func workspacePickerListsAutoThenOpenWorkspacesAndStartsOnTheCurrentOne() {
        let ids = (0..<3).map { _ in UUID() }
        let options = zip(ids, ["toastty", "emptyos", "toastty-ios"]).map {
            QuickEntryModel.Option(id: $0.uuidString, title: $1)
        }
        let picker = QuickEntryPicker(workspaces: options, current: ids[1])
        #expect(picker.rows.map(\.title) == ["Auto", "toastty", "emptyos", "toastty-ios"])
        #expect(picker.highlightedRow?.title == "emptyos")

        picker.query = "tios"
        #expect(picker.rows.map(\.title) == ["toastty-ios"])
        #expect(picker.highlightedRow?.title == "toastty-ios")

        let choices = Box<[QuickEntryPicker.Choice]>([])
        picker.onChoose = { choices.value.append($0) }
        picker.submit()
        #expect(choices.value == [.workspace(ids[2])])

        picker.query = "auto"
        #expect(picker.rows.map(\.title) == ["Auto"])
        picker.submit()
        #expect(choices.value.last == .workspace(nil))

        picker.query = "zzz"
        #expect(picker.rows.isEmpty)
        picker.submit()
        #expect(choices.value.count == 2, "Return with no match chooses nothing")
    }

    @Test func arrowsMoveTheHighlightAndStopAtTheEnds() {
        let options = ["a", "b"].map { QuickEntryModel.Option(id: UUID().uuidString, title: $0) }
        let picker = QuickEntryPicker(workspaces: options, current: nil)
        #expect(picker.highlightedRow?.title == "Auto")
        picker.move(-1)
        #expect(picker.highlightedRow?.title == "Auto")
        picker.move(1)
        picker.move(1)
        picker.move(1)
        #expect(picker.highlightedRow?.title == "b")
    }

    // MARK: - Agent list

    @Test func agentPickerListsFrequentThenAutoAndColumnsAndStartsOnTheTopPreset() {
        let (picker, _) = agentPicker()
        #expect(picker.rows.map(\.title) == ["Claude Code · claude-opus-5-5", "Auto", "Choose agent, model, effort…"])
        #expect(picker.rows.map(\.section) == ["Frequent", "Other", "Other"])
        #expect(picker.rows.first?.detail == "high")
        #expect(picker.highlightedRow?.action == .preset(Self.opusHigh), "On Auto, ⌘2 then Return picks the top preset")

        // A pinned preset that is listed is where the picker starts.
        let sonnet = QuickEntryPreset(agent: "claude", model: "claude-sonnet-5-5", effort: "low")
        let (pinned, _) = agentPicker(frequent: [Self.opusHigh, sonnet], current: sonnet)
        #expect(pinned.highlightedRow?.action == .preset(sonnet))
    }

    @Test func aPinnedPresetThatIsNotFrequentIsListedAsCurrentAndKeptByReturn() {
        let xhigh = QuickEntryPreset(agent: "claude", model: "claude-opus-5-5", effort: "xhigh")
        let (picker, choices) = agentPicker(current: xhigh)
        #expect(picker.rows.map(\.section) == ["Current", "Frequent", "Other", "Other"])
        #expect(picker.highlightedRow?.action == .preset(xhigh))
        picker.submit()
        #expect(choices.value == [.agent(xhigh)], "Return keeps the pinned preset")
    }

    @Test func numberKeysPickAFrequentPresetOnlyWhileTheSearchIsEmpty() {
        let gptHigh = QuickEntryPreset(agent: "codex", model: "gpt-6.1-sol", effort: "high")
        let (picker, choices) = agentPicker(frequent: [Self.opusHigh, gptHigh])
        #expect(picker.rows.map(\.number) == [1, 2, nil, nil])
        #expect(picker.chooseFrequent(number: 3) == false)
        #expect(picker.chooseFrequent(number: 2))
        #expect(choices.value == [.agent(gptHigh)])

        // A pinned preset under Current has no number.
        let xhigh = QuickEntryPreset(agent: "claude", model: "claude-opus-5-5", effort: "xhigh")
        let (pinned, _) = agentPicker(frequent: [Self.opusHigh], current: xhigh)
        #expect(pinned.rows.map(\.number) == [nil, 1, nil, nil])

        // Once there is a search, digits are part of it.
        picker.query = "gpt"
        #expect(picker.rows.allSatisfy { $0.number == nil })
        #expect(picker.chooseFrequent(number: 1) == false)
        picker.query = ""
        picker.openColumns()
        #expect(picker.chooseFrequent(number: 1) == false)
    }

    @Test func presetsOfProfilesThatAreGoneAreNotListed() {
        let (picker, _) = agentPicker(frequent: [QuickEntryPreset(agent: "gemini", model: "gemini-pro"), Self.opusHigh])
        #expect(picker.rows.filter { $0.section == "Frequent" }.map(\.title) == ["Claude Code · claude-opus-5-5"])
    }

    @Test func searchListsMatchingPresetsFirstThenAgentModelPairs() {
        let gptHigh = QuickEntryPreset(agent: "codex", model: "gpt-6.1-sol", effort: "high")
        let (picker, choices) = agentPicker(frequent: [Self.opusHigh, gptHigh])
        picker.query = "gpt"
        #expect(picker.rows.map(\.title) == [
            "Codex · gpt-6.1-sol",
            "Codex · gpt-6.1-sol",
            "Codex · gpt-6-astra",
        ])
        #expect(picker.rows.map(\.section) == ["Frequent", "Models", "Models"])
        #expect(picker.rows[1].detail == "pick effort →")

        // A preset chooses at once.
        picker.submit()
        #expect(choices.value == [.agent(gptHigh)])

        // Every word must match, in any order of the row's text.
        picker.query = "astra cod"
        #expect(picker.rows.map(\.title) == ["Codex · gpt-6-astra"])

        // An agent's own row, for its default model.
        picker.query = "shipper"
        #expect(picker.rows.first?.title == "Shipper (Codex, release authority)")
    }

    @Test func aModelRowWithoutAnEffortOpensTheEffortColumn() throws {
        let (picker, choices) = agentPicker()
        picker.query = "astra"
        picker.submit()
        #expect(choices.value.isEmpty)
        let columns = try #require(picker.columns)
        #expect(columns.agentID == "codex")
        #expect(columns.model == "gpt-6-astra")
        #expect(columns.focused == .effort)
        #expect(picker.query.isEmpty)

        picker.query = "xh"
        picker.submit()
        #expect(choices.value == [.agent(QuickEntryPreset(agent: "codex", model: "gpt-6-astra", effort: "xhigh"))])
    }

    @Test func aRowForAProfileWithNoModelOrEffortChoosesAtOnce() {
        let (picker, choices) = agentPicker()
        picker.query = "composer"
        picker.submit()
        #expect(choices.value == [.agent(QuickEntryPreset(agent: "cursor", model: "composer-2"))], "Cursor takes no effort")

        picker.query = "shipper"
        picker.submit()
        #expect(choices.value.last == .agent(QuickEntryPreset(agent: "shipper")))
        #expect(picker.columns == nil)
    }

    @Test func leftAndRightStepTheHighlightedPresetsEffort() {
        let (picker, choices) = agentPicker()
        #expect(picker.adjustEffort(1))
        #expect(picker.rows.first?.detail == "xhigh")
        #expect(picker.adjustEffort(1))
        #expect(picker.adjustEffort(1), "The key is used even at the top")
        #expect(picker.rows.first?.detail == "max")
        for _ in 0..<6 {
            _ = picker.adjustEffort(-1)
        }
        // Default comes below the lowest effort.
        #expect(picker.rows.first?.detail == "default")
        #expect(picker.highlightedRow?.id == picker.rows.first?.id, "The highlight stays on its row")
        _ = picker.adjustEffort(1)
        picker.submit()
        #expect(choices.value == [.agent(QuickEntryPreset(agent: "claude", model: "claude-opus-5-5", effort: "low"))])

        // On any other row the arrows move the caret.
        picker.move(1)
        #expect(picker.highlightedRow?.title == "Auto")
        #expect(picker.adjustEffort(1) == false)
    }

    @Test func autoAndColumnsRows() {
        let (picker, choices) = agentPicker()
        // "auto" also matches inside "release authority"; a row whose
        // title starts with the search comes first.
        picker.query = "auto"
        #expect(picker.rows.map(\.title) == ["Auto", "Shipper (Codex, release authority)", "Choose agent, model, effort…"])
        picker.submit()
        #expect(choices.value == [.agent(nil)])

        picker.query = "choose"
        picker.submit()
        #expect(picker.columns != nil)
    }

    // MARK: - Columns

    @Test func columnsStartFromThePinnedPresetAndHideWhatTheProfileCannotTake() throws {
        let (picker, _) = agentPicker(current: Self.opusHigh)
        picker.openColumns()
        var columns = try #require(picker.columns)
        #expect(columns.visibleColumns == [.agent, .model, .effort])
        #expect(columns.focused == .agent)
        #expect(columns.preset == Self.opusHigh)
        #expect(columns.cells(in: .model).map(\.title) == ["claude-opus-5-5", "claude-sonnet-5-5", "Default", "Type a model…"])
        #expect(columns.cells(in: .effort).map(\.title) == ["low", "medium", "high", "xhigh", "max", "Default"])

        // Cursor takes no effort: the column goes, and so does the effort.
        picker.query = "cursor"
        columns = try #require(picker.columns)
        #expect(columns.agentID == "cursor")
        #expect(columns.visibleColumns == [.agent, .model])
        #expect(columns.preset == QuickEntryPreset(agent: "cursor"))

        // Shipper takes neither.
        picker.query = "shipper"
        columns = try #require(picker.columns)
        #expect(columns.visibleColumns == [.agent])
        #expect(columns.preset == QuickEntryPreset(agent: "shipper"))
    }

    @Test func tabMovesBetweenColumnsAndTypingFiltersTheFocusedOne() throws {
        let (picker, choices) = agentPicker()
        picker.openColumns()
        picker.query = "codex"
        #expect(picker.columns?.agentID == "codex")
        #expect(picker.columns?.model == nil, "Claude's model does not carry over to Codex")

        picker.tab(1)
        #expect(picker.columns?.focused == .model)
        #expect(picker.query.isEmpty)
        // Default, at the bottom, is chosen; ↑ goes to the models.
        picker.move(1)
        #expect(picker.columns?.model == nil)
        picker.move(-1)
        #expect(picker.columns?.model == "gpt-6-astra")
        picker.move(-1)
        picker.move(-1)
        #expect(picker.columns?.model == "gpt-6.1-sol")
        picker.move(1)

        picker.tab(1)
        picker.query = "hi"
        #expect(picker.columns?.effort == "high")
        picker.tab(1)
        #expect(picker.columns?.focused == .agent, "Tab wraps around")
        picker.tab(-1)
        #expect(picker.columns?.focused == .effort)

        picker.submit()
        #expect(choices.value == [.agent(QuickEntryPreset(agent: "codex", model: "gpt-6-astra", effort: "high"))])
    }

    @Test func aModelCanBeTyped() throws {
        let (picker, choices) = agentPicker()
        picker.openColumns(agent: "claude")
        #expect(picker.columns?.focused == .model)

        // A match is chosen while it fits; a new name is offered after it.
        picker.query = "sonnet"
        var cells = try #require(picker.columns).cells(in: .model)
        #expect(cells.map(\.title) == ["claude-sonnet-5-5", "Use “sonnet”"])
        #expect(picker.columns?.model == "claude-sonnet-5-5")

        // Once chosen, the typed model is listed like the others.
        picker.query = "claude-fable-5-1"
        cells = try #require(picker.columns).cells(in: .model)
        #expect(cells.map(\.title) == ["claude-fable-5-1"])
        #expect(picker.columns?.model == "claude-fable-5-1")

        // The typed model stays listed after Tab clears the search.
        picker.tab(1)
        cells = try #require(picker.columns).cells(in: .model)
        #expect(cells.first?.title == "claude-fable-5-1")
        picker.submit()
        // The effort came from the preset the columns started from.
        #expect(choices.value == [.agent(QuickEntryPreset(agent: "claude", model: "claude-fable-5-1", effort: "high"))])

        // A model is one word.
        let (other, _) = agentPicker()
        other.openColumns(agent: "claude")
        other.query = "two words"
        cells = try #require(other.columns).cells(in: .model)
        #expect(cells.last?.title == "A model is one word")
        #expect(cells.last?.isSelectable == false)
    }

    @Test func returnDoesNothingWhileTheFocusedColumnMatchesNothing() {
        let (picker, choices) = agentPicker(current: Self.opusHigh)
        picker.openColumns()
        picker.query = "gemini"
        #expect(picker.columns?.hasMatch == false)
        picker.submit()
        #expect(choices.value.isEmpty, "Claude Code, still chosen, is not shown")

        picker.tab(1)
        picker.query = "two words"
        picker.submit()
        #expect(choices.value.isEmpty, "A model is one word")

        picker.query = ""
        picker.submit()
        #expect(choices.value == [.agent(Self.opusHigh)])
    }

    @Test func aClickChoosesACellAndFocusesItsColumn() throws {
        let (picker, _) = agentPicker(current: Self.opusHigh)
        picker.openColumns()
        let cell = try #require(picker.columns?.cells(in: .effort).first { $0.title == "max" })
        picker.select(cell, in: .effort)
        #expect(picker.columns?.focused == .effort)
        #expect(picker.columns?.effort == "max")
    }

    // MARK: - Placement

    @Test func thePickerHangsBelowItsPillAndMovesAboveOnlyWithoutRoom() {
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: 420, height: 300)
        // Room below: the top sits just under the pill, left edges aligned.
        let low = QuickEntryPickerPlacement.frame(size: size, pill: NSRect(x: 100, y: 400, width: 120, height: 26), visibleFrame: visible)
        #expect(low.opensUpward == false)
        #expect(low.frame == NSRect(x: 100, y: 400 - QuickEntryPickerPlacement.gap - 300, width: 420, height: 300))
        // Near the bottom: above the pill.
        let high = QuickEntryPickerPlacement.frame(size: size, pill: NSRect(x: 100, y: 100, width: 120, height: 26), visibleFrame: visible)
        #expect(high.opensUpward)
        #expect(high.frame.minY == 126 + QuickEntryPickerPlacement.gap)
        // No room either way: kept on screen, from the bottom.
        let tall = QuickEntryPickerPlacement.frame(size: NSSize(width: 420, height: 700), pill: NSRect(x: 900, y: 300, width: 80, height: 26), visibleFrame: visible)
        #expect(tall.frame.minY == 0)
        #expect(tall.frame.maxX == 1000, "Kept inside the right edge")
    }

    // MARK: - Pill

    @Test func theAgentPillShowsModelAndEffortAndNamesTheProfileOnlyWithoutAModel() {
        let model = QuickEntryModel(
            prefill: .empty,
            workspaceOptions: [],
            agentProfiles: Self.profiles,
            frequentPresets: [],
            stagingDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            create: { _ in throw TaskError("not used") },
            onCreated: { _ in },
            onCancel: {}
        )
        #expect(model.agentTitle == "Auto")
        model.preset = Self.opusHigh
        #expect(model.agentTitle == "claude-opus-5-5 · high")
        model.preset = QuickEntryPreset(agent: "claude", effort: "high")
        #expect(model.agentTitle == "Claude Code · high")
        model.preset = QuickEntryPreset(agent: "shipper")
        #expect(model.agentTitle == "Shipper (Codex, release authority)")
        model.preset = QuickEntryPreset(agent: "cursor", model: "composer-2")
        #expect(model.agentTitle == "composer-2")
        model.close()
    }
}
