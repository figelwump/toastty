import Foundation
import SwiftUI

@MainActor
final class CommandPaletteViewModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            refreshResults()
        }
    }

    @Published private(set) var results: [PaletteCommandResult] = []
    @Published private(set) var selectedIndex = 0

    let originWindowID: UUID
    let focusRequestID = UUID()

    private let commands: [PaletteCommand]
    private let actions: CommandPaletteActionHandling
    private let onCancel: () -> Void
    private let onExecuted: () -> Void

    init(
        originWindowID: UUID,
        commands: [PaletteCommand],
        actions: CommandPaletteActionHandling,
        onCancel: @escaping () -> Void,
        onExecuted: @escaping () -> Void
    ) {
        self.originWindowID = originWindowID
        self.commands = commands
        self.actions = actions
        self.onCancel = onCancel
        self.onExecuted = onExecuted
        refreshResults()
    }

    var selectedResult: PaletteCommandResult? {
        guard results.indices.contains(selectedIndex) else {
            return nil
        }
        return results[selectedIndex]
    }

    func moveSelection(delta: Int) {
        guard results.isEmpty == false else { return }
        let nextIndex = (selectedIndex + delta).positiveModulo(results.count)
        selectedIndex = nextIndex
    }

    func select(index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    func submitSelection() {
        guard let result = selectedResult else { return }
        let context = CommandExecutionContext(originWindowID: originWindowID, actions: actions)
        guard result.command.execute(context) else { return }
        onExecuted()
    }

    func dismiss() {
        onCancel()
    }

    private func refreshResults() {
        let context = CommandExecutionContext(originWindowID: originWindowID, actions: actions)
        let normalizedQuery = query.normalizedPaletteQuery
        let previouslySelectedID = selectedResult?.id

        results = commands.compactMap { command in
            guard command.isAvailable(context) else {
                return nil
            }

            let title = command.title(context)
            guard normalizedQuery.isEmpty || Self.matches(command: command, title: title, query: normalizedQuery) else {
                return nil
            }

            return PaletteCommandResult(command: command, title: title)
        }

        if let previouslySelectedID,
           let preservedIndex = results.firstIndex(where: { $0.id == previouslySelectedID }) {
            selectedIndex = preservedIndex
            return
        }

        selectedIndex = results.isEmpty ? 0 : min(selectedIndex, results.count - 1)
    }

    private static func matches(
        command: PaletteCommand,
        title: String,
        query: String
    ) -> Bool {
        if title.normalizedPaletteQuery.contains(query) {
            return true
        }

        return command.keywords.contains { keyword in
            keyword.normalizedPaletteQuery.contains(query)
        }
    }
}

private extension Int {
    func positiveModulo(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let remainder = self % count
        return remainder >= 0 ? remainder : remainder + count
    }
}

private extension String {
    var normalizedPaletteQuery: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
