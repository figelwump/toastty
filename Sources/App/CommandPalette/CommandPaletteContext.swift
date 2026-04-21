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

enum PaletteMode: Equatable, Sendable {
    case commands
    case fileOpen
}

enum PaletteFileSearchScopeKind: Equatable, Sendable {
    case repositoryRoot
    case workingDirectory

    var label: String {
        switch self {
        case .repositoryRoot:
            return "Repo"
        case .workingDirectory:
            return "Directory"
        }
    }
}

struct PaletteFileSearchScope: Equatable, Sendable {
    let rootPath: String
    let kind: PaletteFileSearchScopeKind

    var displayPath: String {
        NSString(string: rootPath).abbreviatingWithTildeInPath
    }

    var label: String {
        "\(kind.label): \(displayPath)"
    }
}

enum PaletteFileOpenDestination: Equatable, Sendable {
    case localDocument(filePath: String)
    case browser(fileURLString: String)

    var normalizedFilePath: String {
        switch self {
        case .localDocument(let filePath):
            return filePath
        case .browser(let fileURLString):
            return URL(string: fileURLString)?.path ?? fileURLString
        }
    }
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

struct PaletteFileResult: Identifiable, Equatable, Sendable {
    let filePath: String
    let fileName: String
    let relativePath: String
    let destination: PaletteFileOpenDestination

    var id: String { filePath }
    var title: String { fileName }
    var subtitle: String? { relativePath }
    var usageKey: String { "file-open:\(filePath)" }
}

enum PaletteResult: Identifiable, Equatable, Sendable {
    case command(PaletteCommandResult)
    case file(PaletteFileResult)

    var id: String {
        switch self {
        case .command(let result):
            return result.id
        case .file(let result):
            return result.id
        }
    }

    var title: String {
        switch self {
        case .command(let result):
            return result.title
        case .file(let result):
            return result.title
        }
    }

    var subtitle: String? {
        switch self {
        case .command:
            return nil
        case .file(let result):
            return result.subtitle
        }
    }

    var shortcutSymbolLabel: String? {
        switch self {
        case .command(let result):
            return result.command.shortcut?.symbolLabel
        case .file:
            return nil
        }
    }

    var usageKey: String? {
        switch self {
        case .command(let result):
            return result.command.usageKey
        case .file(let result):
            return result.usageKey
        }
    }
}
