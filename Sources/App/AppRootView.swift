import SwiftUI

struct AppRootView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    let automationLifecycle: AutomationLifecycle?
    let automationStartupError: String?
    let disableAnimations: Bool
    @State private var fontHUDPoints: Double?
    @State private var hideFontHUDTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(store: store)
                .frame(width: 200)
            Divider()
            WorkspaceView(store: store, terminalRuntimeRegistry: terminalRuntimeRegistry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if let fontHUDPoints {
                FontHUD(points: fontHUDPoints)
                    .padding(.top, 12)
            }
        }
        .task {
            terminalRuntimeRegistry.synchronize(with: store.state)
            automationLifecycle?.markReady(runtimeError: automationStartupError)
        }
        .onChange(of: store.state) { _, nextState in
            terminalRuntimeRegistry.synchronize(with: nextState)
        }
        .onChange(of: store.state.globalTerminalFontPoints) { _, nextPoints in
            fontHUDPoints = nextPoints
            hideFontHUDTask?.cancel()
            hideFontHUDTask = Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard Task.isCancelled == false else { return }
                await MainActor.run {
                    fontHUDPoints = nil
                    hideFontHUDTask = nil
                }
            }
        }
        .onDisappear {
            hideFontHUDTask?.cancel()
            hideFontHUDTask = nil
        }
        .transaction { transaction in
            if disableAnimations {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
    }
}

private struct FontHUD: View {
    let points: Double

    var body: some View {
        Text("Terminal Font \(Int(points))")
            .font(.headline.monospaced())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
    }
}
