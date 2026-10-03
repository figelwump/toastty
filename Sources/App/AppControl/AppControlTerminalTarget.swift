import CoreState
import Foundation

extension AppControlExecutor {
    struct TerminalActionTarget {
        let windowID: UUID
        let workspaceID: UUID
        let tabID: UUID
        let panelID: UUID
    }

    /// Resolves a complete target once, before creation or an asynchronous launch.
    /// Explicit selectors constrain each other; an invalid selector never falls
    /// back to the user's current selection.
    func resolveTerminalActionTarget(
        args: [String: AutomationJSONValue],
        forLaunch: Bool
    ) throws -> TerminalActionTarget {
        let state = try requiredStore().state
        let windowID = try optionalUUIDParameter("windowID", args: args)
        let workspaceID = try optionalUUIDParameter("workspaceID", args: args)
        let tabID = try optionalUUIDParameter("tabID", args: args)
        let panelID = try optionalUUIDParameter("panelID", args: args)
        let caller = callerManagedSession()
        let callerSelection = caller.flatMap { state.workspaceSelection(containingPanelID: $0.panelID) }
        let callerTabID = caller.flatMap { callerSelection?.workspace.tabID(containingPanelID: $0.panelID) }

        let selection: WindowWorkspaceSelection
        if let panelID {
            guard let located = state.workspaceSelection(containingPanelID: panelID) else {
                throw AutomationSocketError.invalidPayload("panelID does not exist")
            }
            selection = located
        } else if let workspaceID {
            guard let located = state.workspaceSelection(containingWorkspaceID: workspaceID) else {
                throw AutomationSocketError.invalidPayload("workspaceID does not exist")
            }
            selection = located
        } else if let tabID {
            guard let workspace = state.workspacesByID.values.first(where: { $0.tabsByID[tabID] != nil }),
                  let located = state.workspaceSelection(containingWorkspaceID: workspace.id) else {
                throw AutomationSocketError.invalidPayload("tabID does not exist")
            }
            selection = located
        } else if let windowID {
            guard let located = state.workspaceSelection(in: windowID) else {
                throw AutomationSocketError.invalidPayload("windowID does not exist or has no selected workspace")
            }
            selection = located
        } else if let callerSelection, callerTabID != nil {
            selection = callerSelection
        } else if requestContext().callerSessionID != nil {
            throw AutomationSocketError.invalidPayload(
                "workspaceID, tabID or panelID is required: the calling session has no active managed terminal"
            )
        } else if forLaunch, let selected = state.selectedWorkspaceSelection() {
            // Manual/external launch callers retain their selected-window default.
            selection = selected
        } else {
            selection = try resolveWorkspaceSelection(args: args)
        }

        if let workspaceID, workspaceID != selection.workspaceID {
            throw AutomationSocketError.invalidPayload("panelID does not belong to workspaceID")
        }
        if let windowID, windowID != selection.windowID {
            throw AutomationSocketError.invalidPayload("workspaceID does not belong to windowID")
        }
        try enforceWorkspaceAutomationAccess(selection.workspaceID)

        let workspace = selection.workspace
        let resolvedTabID: UUID
        if let panelID {
            guard let locatedTabID = workspace.tabID(containingPanelID: panelID) else {
                throw AutomationSocketError.invalidPayload("panelID is not in a workspace tab's main layout")
            }
            if let tabID, tabID != locatedTabID {
                throw AutomationSocketError.invalidPayload("panelID does not belong to tabID")
            }
            resolvedTabID = locatedTabID
        } else if let tabID {
            resolvedTabID = tabID
        } else if callerSelection?.workspaceID == selection.workspaceID, let callerTabID {
            resolvedTabID = callerTabID
        } else if let selectedTabID = workspace.resolvedSelectedTabID {
            resolvedTabID = selectedTabID
        } else {
            throw AutomationSocketError.invalidPayload("workspace has no tab")
        }
        guard let tab = workspace.tab(id: resolvedTabID) else {
            throw AutomationSocketError.invalidPayload("tabID does not belong to workspaceID")
        }

        let resolvedPanelID: UUID
        if let panelID {
            resolvedPanelID = panelID
        } else if forLaunch {
            if let focusedID = tab.resolvedFocusedPanelID, case .terminal = tab.panels[focusedID] {
                resolvedPanelID = focusedID
            } else if let terminal = tab.layoutTree.allSlotInfos.first(where: {
                if case .terminal = tab.panels[$0.panelID] { return true }
                return false
            }) {
                resolvedPanelID = terminal.panelID
            } else {
                throw AgentLaunchError.workspaceHasNoTerminalPanel
            }
        } else if let focusedID = tab.resolvedFocusedPanelID {
            resolvedPanelID = focusedID
        } else {
            throw AutomationSocketError.invalidPayload("tab has no panel to split")
        }
        if forLaunch {
            guard case .terminal = tab.panels[resolvedPanelID] else {
                throw AgentLaunchError.panelIsNotTerminal
            }
        }
        return TerminalActionTarget(
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            tabID: resolvedTabID,
            panelID: resolvedPanelID
        )
    }

    func createTerminalTab(args: [String: AutomationJSONValue]) throws -> AppControlActionOutcome {
        // A new tab has no existing tab or panel to target. The workspace is its parent.
        guard args["tabID"] == nil, args["panelID"] == nil else {
            throw AutomationSocketError.invalidPayload("workspace.tab.create accepts a workspace or window target")
        }
        _ = try optionalUUIDParameter("workspaceID", args: args)
        _ = try optionalUUIDParameter("windowID", args: args)
        let workspaceID: UUID
        if args["workspaceID"] != nil || args["windowID"] != nil {
            workspaceID = try resolveWorkspaceSelection(args: args).workspaceID
        } else if let caller = callerManagedSession(),
                  let selection = try requiredStore().state.workspaceSelection(containingPanelID: caller.panelID) {
            workspaceID = selection.workspaceID
        } else if requestContext().callerSessionID != nil {
            throw AutomationSocketError.invalidPayload("the calling session has no active managed terminal")
        } else {
            workspaceID = try resolveWorkspaceSelection(args: args).workspaceID
        }
        try enforceWorkspaceAutomationAccess(workspaceID)
        let activate = try optionalBooleanParameter("activate", args: args, defaultValue: true)
        let store = try requiredStore()
        let previousTabIDs = Set(store.state.workspacesByID[workspaceID]?.tabIDs ?? [])
        let changed = store.sendNavigation(.createWorkspaceTab(workspaceID: workspaceID, seed: nil, activate: activate))
        guard changed else { return .init(didMutateState: false, result: nil) }
        guard let workspace = store.state.workspacesByID[workspaceID],
              let tabID = workspace.tabIDs.first(where: { !previousTabIDs.contains($0) }),
              let panelID = workspace.tab(id: tabID)?.focusedPanelID else {
            throw AutomationSocketError.internalError("created tab has no terminal panel")
        }
        return .init(didMutateState: true, result: [
            "workspaceID": .string(workspaceID.uuidString),
            "tabID": .string(tabID.uuidString),
            "panelID": .string(panelID.uuidString),
        ])
    }

    func validateTabParameter(_ args: [String: AutomationJSONValue], descriptor: AppControlCommandDescriptor) throws {
        if args["tabID"] != nil, !descriptor.parameters.contains(where: { $0.name == "tabID" }) {
            throw AutomationSocketError.invalidPayload("\(descriptor.id) does not support tabID")
        }
    }
}
