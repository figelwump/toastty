import CoreState
import Foundation

// Shared built-in projection for the palette's current high-frequency slice.
enum CommandPaletteCatalog {
    static func commands() -> [PaletteCommand] {
        [
            makeCommand(
                .splitRight,
                isAvailable: { context in
                    context.actions.canSplit(direction: .right, originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.split(direction: .right, originWindowID: context.originWindowID)
                }
            ),
            makeCommand(
                .splitDown,
                isAvailable: { context in
                    context.actions.canSplit(direction: .down, originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.split(direction: .down, originWindowID: context.originWindowID)
                }
            ),
            makeCommand(
                .newWorkspace,
                isAvailable: { context in
                    context.actions.canCreateWorkspace(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.createWorkspace(originWindowID: context.originWindowID)
                }
            ),
            makeCommand(
                .newTab,
                isAvailable: { context in
                    context.actions.canCreateWorkspaceTab(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.createWorkspaceTab(originWindowID: context.originWindowID)
                }
            ),
            makeCommand(
                .toggleSidebar,
                title: { context in
                    context.actions.sidebarTitle(originWindowID: context.originWindowID)
                },
                isAvailable: { context in
                    context.actions.canToggleSidebar(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.toggleSidebar(originWindowID: context.originWindowID)
                }
            ),
            makeCommand(
                .closePanel,
                isAvailable: { context in
                    context.actions.canClosePanel(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.closePanel(originWindowID: context.originWindowID)
                }
            ),
            makeCommand(
                .reloadConfiguration,
                isAvailable: { context in
                    context.actions.canReloadConfiguration()
                },
                execute: { context in
                    context.actions.reloadConfiguration()
                }
            ),
        ]
    }

    private static func makeCommand(
        _ builtInCommand: ToasttyBuiltInCommand,
        title: @escaping @MainActor (CommandExecutionContext) -> String,
        isAvailable: @escaping @MainActor (CommandExecutionContext) -> Bool,
        execute: @escaping @MainActor (CommandExecutionContext) -> Bool
    ) -> PaletteCommand {
        PaletteCommand(
            id: builtInCommand.id,
            keywords: builtInCommand.keywords,
            shortcut: builtInCommand.shortcut,
            title: title,
            isAvailable: isAvailable,
            execute: execute
        )
    }

    private static func makeCommand(
        _ builtInCommand: ToasttyBuiltInCommand,
        isAvailable: @escaping @MainActor (CommandExecutionContext) -> Bool,
        execute: @escaping @MainActor (CommandExecutionContext) -> Bool
    ) -> PaletteCommand {
        makeCommand(
            builtInCommand,
            title: { _ in builtInCommand.title },
            isAvailable: isAvailable,
            execute: execute
        )
    }
}
