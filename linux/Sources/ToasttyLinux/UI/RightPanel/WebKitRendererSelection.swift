import Foundation

/// Keeps WebKit on its GPU (DMA-BUF) renderer on NVIDIA. Ubuntu's WebKitGTK
/// carries Debian's `disable-nvidia-dmabuf.patch`, which turns that renderer
/// off when the NVIDIA driver is loaded; GTK 4 WebKit has no other
/// accelerated path, so pages fall back to hardware acceleration "never" and
/// GTK repaints every web-view frame through Cairo on Toastty's main thread.
/// At 4K that took ~80 ms a frame, so typing in a local document or scrolling
/// a page lagged; with the renderer forced back on, frames stay at 16 ms.
///
/// WebKit reads `WEBKIT_FORCE_DMABUF_RENDERER` (the patch's opt-out) once,
/// when the web context is created, so the variable is set only around that
/// call and then restored: shells and agents inherit the user's environment
/// unchanged. An explicit `WEBKIT_FORCE_DMABUF_RENDERER` or
/// `WEBKIT_DISABLE_DMABUF_RENDERER` (e.g. to work around a driver bug) is
/// respected.
enum WebKitRendererSelection {
    static let forceVariable = "WEBKIT_FORCE_DMABUF_RENDERER"
    static let disableVariable = "WEBKIT_DISABLE_DMABUF_RENDERER"

    static func shouldForceDMABufRenderer(environment: [String: String]) -> Bool {
        environment[forceVariable] == nil && environment[disableVariable] == nil
    }

    /// Runs `createContext` with the DMA-BUF renderer forced on.
    static func withDMABufRenderer<T>(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        _ createContext: () -> T
    ) -> T {
        guard shouldForceDMABufRenderer(environment: environment) else { return createContext() }
        setenv(forceVariable, "1", 1)
        defer { unsetenv(forceVariable) }
        return createContext()
    }
}
