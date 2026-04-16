import Foundation

struct CommandExecutionContext {
    let originWindowID: UUID
    let actions: CommandPaletteActionHandling
}

struct PaletteCommandResult: Identifiable {
    let command: PaletteCommand
    let title: String

    var id: String { command.id }
}

struct PaletteCommand {
    let id: String
    let keywords: [String]
    let shortcut: ToasttyKeyboardShortcut?
    let title: @MainActor (CommandExecutionContext) -> String
    let isAvailable: @MainActor (CommandExecutionContext) -> Bool
    let execute: @MainActor (CommandExecutionContext) -> Bool
}
