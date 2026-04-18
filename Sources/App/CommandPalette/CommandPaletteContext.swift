import CoreState
import Foundation

struct PaletteShortcut: Equatable, Sendable {
    let symbolLabel: String

    init(symbolLabel: String) {
        self.symbolLabel = symbolLabel
    }

    init(_ shortcut: ToasttyKeyboardShortcut) {
        self.init(symbolLabel: shortcut.symbolLabel)
    }

    init(_ shortcut: ShortcutChord) {
        self.init(symbolLabel: shortcut.symbolLabel)
    }
}

struct PaletteWorkspaceSwitchOption: Equatable, Sendable {
    let workspaceID: UUID
    let title: String
    let shortcut: PaletteShortcut?
}

enum PaletteCommandInvocation: Equatable, Sendable {
    case builtIn(ToasttyBuiltInCommand)
    case workspaceSwitch(workspaceID: UUID)
    case agentProfileLaunch(profileID: String)
    case terminalProfileSplit(profileID: String, direction: SlotSplitDirection)
}

struct PaletteCommandDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let usageKey: String?
    let title: String
    let keywords: [String]
    let shortcut: PaletteShortcut?
    let invocation: PaletteCommandInvocation
}

struct PaletteCommandResult: Identifiable, Equatable, Sendable {
    let command: PaletteCommandDescriptor

    var id: String { command.id }
    var title: String { command.title }
}
