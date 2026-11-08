import Foundation

/// Whether a Codex executable accepts `--no-daemon`.
///
/// Since 0.157 the Codex TUI runs its sessions in a shared background
/// app-server daemon unless the launch opts out. The daemon runs hooks with
/// the environment of whichever terminal started it, so hooks from every
/// later session report that first session's `TOASTTY_SESSION_ID`,
/// `TOASTTY_PANEL_ID` and `TOASTTY_SOCKET_PATH`: status tracking breaks, and
/// it stays broken after that Toastty quits. Managed launches therefore pass
/// `--no-daemon` (added in 0.156); older Codex rejects the flag, so it is only
/// added when `codex --help` lists it. Results are cached per executable
/// identity (resolved path, inode, size, modification time).
final class CodexDaemonOptOutProbe: @unchecked Sendable {
    static let flag = "--no-daemon"

    private let fileManager: FileManager
    private let executor: any CodexPluginCLIExecuting
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cache: [String: Bool] = [:]

    init(
        fileManager: FileManager = .default,
        executor: (any CodexPluginCLIExecuting)? = nil,
        timeout: TimeInterval = 3
    ) {
        self.fileManager = fileManager
        self.executor = executor ?? CodexPluginCLIProcessExecutor(fileManager: fileManager)
        self.timeout = timeout
    }

    func supportsNoDaemon(runtime: CodexIntegrationRuntime) -> Bool {
        let key = identityKey(for: runtime.executableURL)
        if let cached = lock.withLock({ cache[key] }) {
            return cached
        }
        let help: Data
        do {
            help = try executor.execute(
                runtime: runtime,
                arguments: ["--help"],
                deadline: Date().addingTimeInterval(timeout)
            )
        } catch CodexPluginCLIError.timedOut {
            // Not cached: a slow first start says nothing about the flag.
            return false
        } catch {
            lock.withLock { cache[key] = false }
            return false
        }
        let supported = String(decoding: help, as: UTF8.self)
            .range(of: #"(^|\s)--no-daemon(\s|$)"#, options: .regularExpression) != nil
        lock.withLock { cache[key] = supported }
        return supported
    }

    private func identityKey(for executableURL: URL) -> String {
        let resolvedPath = executableURL.resolvingSymlinksInPath().path
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolvedPath) else {
            return "\(resolvedPath)|missing"
        }
        return [
            resolvedPath,
            (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "0",
            (attributes[.size] as? NSNumber)?.stringValue ?? "0",
            String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0),
        ].joined(separator: "|")
    }
}
