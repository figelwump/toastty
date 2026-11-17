import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Linux replacement for `TerminalProcessWorkingDirectoryResolver`
/// (Sources/App/Terminal/TerminalProcessWorkingDirectoryResolver.swift uses
/// `proc_pidinfo`). Same contract for `TerminalMetadataService`: snapshot this
/// process's children before a terminal surface spawns its shell, bind the new
/// child to the panel afterwards, and read that shell's cwd/executable from
/// `/proc`. It is the fallback when a shell does not report OSC 7.
final class TerminalProcessWorkingDirectoryResolver {
    private let appPID: pid_t
    private var shellPIDByPanelID: [UUID: pid_t] = [:]
    private var expectedWorkingDirectoryByPanelID: [UUID: String] = [:]

    init(appPID: pid_t = getpid()) {
        self.appPID = appPID
    }

    func snapshotChildPIDs() -> Set<pid_t> {
        Set(Self.childPIDs(of: appPID))
    }

    func registerNewChild(
        panelID: UUID,
        previousChildren: Set<pid_t>,
        expectedWorkingDirectory: String?,
        isRestoredLaunch: Bool
    ) {
        _ = isRestoredLaunch
        if let expectedWorkingDirectory {
            expectedWorkingDirectoryByPanelID[panelID] = expectedWorkingDirectory
        }
        let candidates = Self.childPIDs(of: appPID).filter { previousChildren.contains($0) == false }
        // One new child per surface; with several (a racing second surface)
        // prefer the one already in the expected directory.
        let chosen = candidates.first { pid in
            guard let expectedWorkingDirectory, let cwd = Self.workingDirectory(of: pid) else { return false }
            return cwd == expectedWorkingDirectory
        } ?? (candidates.count == 1 ? candidates.first : nil)
        if let chosen {
            shellPIDByPanelID[panelID] = Self.interactiveShellPID(startingAt: chosen)
        }
    }

    func resolveWorkingDirectory(for panelID: UUID) -> String? {
        guard let pid = livePID(for: panelID) else { return nil }
        return Self.workingDirectory(of: pid)
    }

    func resolveShellExecutablePath(for panelID: UUID) -> String? {
        guard let pid = livePID(for: panelID) else { return nil }
        return Self.readLink("/proc/\(pid)/exe")
    }

    func invalidate(panelID: UUID) {
        shellPIDByPanelID.removeValue(forKey: panelID)
        expectedWorkingDirectoryByPanelID.removeValue(forKey: panelID)
    }

    func prune(panelIDs: Set<UUID>) {
        shellPIDByPanelID = shellPIDByPanelID.filter { panelIDs.contains($0.key) }
        expectedWorkingDirectoryByPanelID = expectedWorkingDirectoryByPanelID.filter { panelIDs.contains($0.key) }
    }

    private func livePID(for panelID: UUID) -> pid_t? {
        guard let pid = shellPIDByPanelID[panelID] else { return nil }
        guard kill(pid, 0) == 0 || errno == EPERM else {
            shellPIDByPanelID.removeValue(forKey: panelID)
            return nil
        }
        // A login wrapper may have exec'd or spawned the shell since binding.
        let shell = Self.interactiveShellPID(startingAt: pid)
        shellPIDByPanelID[panelID] = shell
        return shell
    }

    /// Follows `login`/wrapper processes down to the first process that is
    /// not one of them (Ghostty may start `/usr/bin/login` or a `sh -c`).
    static func interactiveShellPID(startingAt pid: pid_t) -> pid_t {
        var current = pid
        for _ in 0..<3 {
            let name = (readLink("/proc/\(current)/exe").map { ($0 as NSString).lastPathComponent }) ?? ""
            guard ["login", "sudo", "su"].contains(name),
                  let child = childPIDs(of: current).first else {
                return current
            }
            current = child
        }
        return current
    }

    static func childPIDs(of parent: pid_t) -> [pid_t] {
        // /proc/<pid>/task/<tid>/children lists direct children per thread.
        let taskDirectory = "/proc/\(parent)/task"
        guard let tasks = try? FileManager.default.contentsOfDirectory(atPath: taskDirectory) else { return [] }
        var children: [pid_t] = []
        for task in tasks {
            guard let text = try? String(contentsOfFile: "\(taskDirectory)/\(task)/children", encoding: .utf8) else {
                continue
            }
            children += text.split(separator: " ").compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return children.sorted()
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        readLink("/proc/\(pid)/cwd")
    }

    static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        buffer[count] = 0
        return String(cString: buffer)
    }
}

extension TerminalRuntimeRegistry {
    /// Ghostty surface handles do not cross the Linux seam; notifications and
    /// metadata arrive with their panel ID instead.
    func panelID(forSurfaceHandle surfaceHandle: UInt) -> UUID? {
        _ = surfaceHandle
        return nil
    }
}
