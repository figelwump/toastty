import AppKit
import CoreState
import SwiftUI

struct AppWindowSceneView: View {
    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    let disableAnimations: Bool

    @State private var fontHUDPoints: Double?
    @State private var hideFontHUDTask: Task<Void, Never>?

    private var terminalRuntimeContext: TerminalWindowRuntimeContext {
        TerminalWindowRuntimeContext(
            windowID: windowID,
            runtimeRegistry: terminalRuntimeRegistry
        )
    }

    private var windowState: WindowState? {
        store.window(id: windowID)
    }

    var body: some View {
        Group {
            if windowState != nil {
                AppWindowView(
                    windowID: windowID,
                    store: store,
                    terminalRuntimeContext: terminalRuntimeContext
                )
            } else {
                EmptyStateView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ToastyTheme.chromeBackground)
        .foregroundStyle(ToastyTheme.primaryText)
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let fontHUDPoints {
                FontHUD(points: fontHUDPoints)
                    .padding(.top, 12)
            }
        }
        .background {
            AppWindowSceneObserver(
                windowID: windowID,
                desiredFrame: windowState?.frame,
                onWindowDidBecomeKey: handleWindowDidBecomeKey,
                onWindowFrameChange: handleWindowFrameChange,
                onWindowWillClose: handleWindowWillClose
            )
        }
        .onDisappear {
            hideFontHUDTask?.cancel()
            hideFontHUDTask = nil
        }
        .onChange(of: store.state.globalTerminalFontPoints) { _, nextPoints in
            fontHUDPoints = nextPoints
            hideFontHUDTask?.cancel()
            hideFontHUDTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(1.2))
                } catch {
                    return
                }
                fontHUDPoints = nil
                hideFontHUDTask = nil
            }
        }
        .transaction { transaction in
            if disableAnimations {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
    }

    private func handleWindowDidBecomeKey() {
        guard windowState != nil else { return }
        _ = store.send(.selectWindow(windowID: windowID))
        scheduleWindowFocusRestore()
    }

    private func handleWindowFrameChange(_ frame: CGRectCodable) {
        _ = store.send(.updateWindowFrame(windowID: windowID, frame: frame))
    }

    private func handleWindowWillClose() {
        guard windowState != nil else { return }
        _ = store.send(.closeWindow(windowID: windowID))
    }

    private func scheduleWindowFocusRestore(avoidStealingKeyboardFocus: Bool = true) {
        guard let workspaceID = store.selectedWorkspace(in: windowID)?.id else { return }
        terminalRuntimeContext.scheduleWorkspaceFocusRestore(
            workspaceID: workspaceID,
            avoidStealingKeyboardFocus: avoidStealingKeyboardFocus
        )
    }
}

private struct FontHUD: View {
    let points: Double

    var body: some View {
        Text("Terminal Font \(Int(points))")
            .font(.headline.monospaced())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(ToastyTheme.primaryText)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(ToastyTheme.hairline, lineWidth: 1)
            )
    }
}
