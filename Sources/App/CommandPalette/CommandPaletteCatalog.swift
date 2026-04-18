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
                .selectPreviousSplit,
                isAvailable: { context in
                    context.actions.canFocusSplit(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.focusSplit(direction: .previous, originWindowID: context.originWindowID)
                }
            ),
            makeCommand(
                .selectNextSplit,
                isAvailable: { context in
                    context.actions.canFocusSplit(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.focusSplit(direction: .next, originWindowID: context.originWindowID)
                }
            ),
            makeCommand(
                .navigateSplitUp,
                isAvailable: { context in
                    context.actions.canFocusSplit(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.focusSplit(direction: .up, originWindowID: context.originWindowID)
                }
            ),
            makeCommand(
                .navigateSplitDown,
                isAvailable: { context in
                    context.actions.canFocusSplit(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.focusSplit(direction: .down, originWindowID: context.originWindowID)
                }
            ),
            makeCommand(
                .navigateSplitLeft,
                isAvailable: { context in
                    context.actions.canFocusSplit(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.focusSplit(direction: .left, originWindowID: context.originWindowID)
                }
            ),
            makeCommand(
                .navigateSplitRight,
                isAvailable: { context in
                    context.actions.canFocusSplit(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.focusSplit(direction: .right, originWindowID: context.originWindowID)
                }
            ),
            makeCommand(
                .equalizeSplits,
                isAvailable: { context in
                    context.actions.canEqualizeSplits(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.equalizeSplits(originWindowID: context.originWindowID)
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
                .newWindow,
                isAvailable: { context in
                    context.actions.canCreateWindow(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.createWindow(originWindowID: context.originWindowID)
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
                .renameWorkspace,
                isAvailable: { context in
                    context.actions.canRenameWorkspace(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.renameWorkspace(originWindowID: context.originWindowID)
                }
            ),
            makeCommand(
                .closeWorkspace,
                isAvailable: { context in
                    context.actions.canCloseWorkspace(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.closeWorkspace(originWindowID: context.originWindowID)
                }
            ),
            makeCommand(
                .renameTab,
                isAvailable: { context in
                    context.actions.canRenameTab(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.renameTab(originWindowID: context.originWindowID)
                }
            ),
            makeCommand(
                .selectPreviousTab,
                isAvailable: { context in
                    context.actions.canSelectAdjacentTab(
                        direction: .previous,
                        originWindowID: context.originWindowID
                    )
                },
                execute: { context in
                    context.actions.selectAdjacentTab(
                        direction: .previous,
                        originWindowID: context.originWindowID
                    )
                }
            ),
            makeCommand(
                .selectNextTab,
                isAvailable: { context in
                    context.actions.canSelectAdjacentTab(
                        direction: .next,
                        originWindowID: context.originWindowID
                    )
                },
                execute: { context in
                    context.actions.selectAdjacentTab(
                        direction: .next,
                        originWindowID: context.originWindowID
                    )
                }
            ),
            makeCommand(
                .jumpToNextActive,
                isAvailable: { context in
                    context.actions.canJumpToNextActive(originWindowID: context.originWindowID)
                },
                execute: { context in
                    context.actions.jumpToNextActive(originWindowID: context.originWindowID)
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
