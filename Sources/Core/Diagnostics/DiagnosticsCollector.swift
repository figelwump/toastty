import Darwin
import Foundation

public enum DiagnosticsCollector {
    public static func collect(
        generatedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        note: String?,
        shellProbeFilePath: String?,
        socket: DiagnosticsSocketProbeResult,
        automation: DiagnosticsAutomationSection? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryPath: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> DiagnosticsBundle {
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
        let instance = DiagnosticsRuntimeInstance.read(
            runtimePaths: runtimePaths,
            fileManager: fileManager
        )

        return DiagnosticsBundle(
            generatedAtMs: generatedAtMs,
            note: note,
            app: DiagnosticsAppCollector.collect(
                runtimePaths: runtimePaths,
                instance: instance,
                fileManager: fileManager
            ),
            logs: DiagnosticsLogCollector.collect(
                runtimePaths: runtimePaths,
                instance: instance.manifest,
                fileManager: fileManager
            ),
            shell: DiagnosticsShellCollector.collect(
                runtimePaths: runtimePaths,
                environment: environment,
                homeDirectoryPath: homeDirectoryPath,
                fileManager: fileManager
            ),
            system: DiagnosticsSystemCollector.collect(),
            socket: socket,
            automation: automation,
            probe: DiagnosticsProbeCollector.collect(
                shellProbeFilePath: shellProbeFilePath,
                fileManager: fileManager
            )
        )
    }
}

struct DiagnosticsRuntimeInstance {
    struct Manifest: Decodable, Equatable {
        let pid: Int32?
        let bundlePath: String?
        let executablePath: String?
        let runtimeHomePath: String?
        let runtimeHomeStrategy: String?
        let runtimeLabel: String?
        let worktreeRootPath: String?
        let logFilePath: String?
        let socketPath: String?
        let runID: String?
    }

    let manifest: Manifest?
    let filePath: String?
    let status: DiagnosticsAvailability

    static func read(
        runtimePaths: ToasttyRuntimePaths,
        fileManager: FileManager = .default
    ) -> DiagnosticsRuntimeInstance {
        guard let instanceFileURL = runtimePaths.instanceFileURL else {
            return DiagnosticsRuntimeInstance(
                manifest: nil,
                filePath: nil,
                status: .unavailable("runtime instance manifest is unavailable for user-home runtime")
            )
        }

        guard fileManager.fileExists(atPath: instanceFileURL.path) else {
            return DiagnosticsRuntimeInstance(
                manifest: nil,
                filePath: instanceFileURL.path,
                status: .unavailable("instance.json not found")
            )
        }

        do {
            let data = try Data(contentsOf: instanceFileURL)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            return DiagnosticsRuntimeInstance(
                manifest: manifest,
                filePath: instanceFileURL.path,
                status: .available
            )
        } catch {
            return DiagnosticsRuntimeInstance(
                manifest: nil,
                filePath: instanceFileURL.path,
                status: .unavailable("failed to read instance.json: \(error.localizedDescription)")
            )
        }
    }
}

private enum DiagnosticsAppCollector {
    static func collect(
        runtimePaths: ToasttyRuntimePaths,
        instance: DiagnosticsRuntimeInstance,
        fileManager: FileManager
    ) -> DiagnosticsAppSection {
        let info = readInfoPlist(bundlePath: instance.manifest?.bundlePath, fileManager: fileManager)
        let pid = instance.manifest?.pid
        return DiagnosticsAppSection(
            shortVersion: info.shortVersion,
            build: info.build,
            bundlePath: instance.manifest?.bundlePath,
            executablePath: instance.manifest?.executablePath,
            runtimeHomePath: instance.manifest?.runtimeHomePath ?? runtimePaths.runtimeHomeURL?.path,
            runtimeHomeStrategy: instance.manifest?.runtimeHomeStrategy ?? runtimePaths.runtimeHomeStrategy.rawValue,
            runtimeLabel: instance.manifest?.runtimeLabel ?? runtimePaths.runtimeLabel,
            isDevWorktree: (instance.manifest?.worktreeRootPath ?? runtimePaths.worktreeRootURL?.path) != nil,
            pid: pid,
            pidAlive: pid.map(isProcessAlive),
            runID: instance.manifest?.runID,
            instanceFilePath: instance.filePath,
            instanceStatus: instance.status,
            infoPlistStatus: info.status
        )
    }

    private static func readInfoPlist(
        bundlePath: String?,
        fileManager: FileManager
    ) -> (shortVersion: String?, build: String?, status: DiagnosticsAvailability) {
        guard let bundlePath, bundlePath.isEmpty == false else {
            return (nil, nil, .unavailable("app bundle path is unknown"))
        }

        let infoPlistURL = URL(fileURLWithPath: bundlePath, isDirectory: true)
            .appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard fileManager.fileExists(atPath: infoPlistURL.path) else {
            return (nil, nil, .unavailable("Info.plist not found at \(infoPlistURL.path)"))
        }

        guard let plist = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] else {
            return (nil, nil, .unavailable("failed to decode Info.plist at \(infoPlistURL.path)"))
        }

        return (
            plist["CFBundleShortVersionString"] as? String,
            plist["CFBundleVersion"] as? String,
            .available
        )
    }
}

private enum DiagnosticsLogCollector {
    static func collect(
        runtimePaths: ToasttyRuntimePaths,
        instance: DiagnosticsRuntimeInstance.Manifest?,
        fileManager: FileManager
    ) -> DiagnosticsLogsSection {
        let currentURL = instance?.logFilePath.map { URL(fileURLWithPath: $0, isDirectory: false) }
            ?? runtimePaths.defaultLogFileURL
        let previousURL = currentURL.deletingPathExtension().appendingPathExtension("previous.log")

        return DiagnosticsLogsSection(
            current: readLogFile(at: currentURL, fileManager: fileManager),
            previous: readLogFile(at: previousURL, fileManager: fileManager),
            configSummary: ToasttyLog.configurationSummary()
        )
    }

    private static func readLogFile(
        at url: URL,
        fileManager: FileManager
    ) -> DiagnosticsLogFile {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let sizeBytes = (attributes?[.size] as? NSNumber)?.uint64Value
        let modifiedAtMs = (attributes?[.modificationDate] as? Date).map(millisecondsSinceEpoch)

        guard fileManager.fileExists(atPath: url.path) else {
            return DiagnosticsLogFile(
                path: url.path,
                exists: false,
                sizeBytes: sizeBytes,
                modifiedAtMs: modifiedAtMs,
                content: nil,
                readError: nil
            )
        }

        do {
            let data = try Data(contentsOf: url)
            return DiagnosticsLogFile(
                path: url.path,
                exists: true,
                sizeBytes: UInt64(data.count),
                modifiedAtMs: modifiedAtMs,
                content: String(decoding: data, as: UTF8.self),
                readError: nil
            )
        } catch {
            return DiagnosticsLogFile(
                path: url.path,
                exists: true,
                sizeBytes: sizeBytes,
                modifiedAtMs: modifiedAtMs,
                content: nil,
                readError: error.localizedDescription
            )
        }
    }
}

private enum DiagnosticsShellCollector {
    private struct ShellDefinition {
        let name: String
        let managedSnippetFileName: String
        let rcPaths: [String]
    }

    private static let shells = [
        ShellDefinition(
            name: "zsh",
            managedSnippetFileName: "toastty-profile-shell-integration.zsh",
            rcPaths: [".zshrc"]
        ),
        ShellDefinition(
            name: "bash",
            managedSnippetFileName: "toastty-profile-shell-integration.bash",
            rcPaths: [".bash_profile", ".profile"]
        ),
        ShellDefinition(
            name: "fish",
            managedSnippetFileName: "toastty-profile-shell-integration.fish",
            rcPaths: [".config/fish/config.fish"]
        ),
    ]

    private static let valueEnvironmentNames: Set<String> = [
        "PATH",
        "SHELL",
        "TERM",
        "TERM_PROGRAM",
    ]

    static func collect(
        runtimePaths: ToasttyRuntimePaths,
        environment: [String: String],
        homeDirectoryPath: String,
        fileManager: FileManager
    ) -> DiagnosticsShellSection {
        let homeURL = URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
        return DiagnosticsShellSection(
            detectedShells: shells.flatMap { shell in
                shell.rcPaths.map { rcPath in
                    inspectInitFile(
                        shell: shell,
                        url: homeURL.appendingPathComponent(rcPath, isDirectory: false),
                        homeURL: homeURL,
                        fileManager: fileManager
                    )
                }
            },
            shimDirectory: listDirectory(runtimePaths.agentShimDirectoryURL, fileManager: fileManager),
            environment: diagnosticEnvironmentEntries(environment),
            otherEnvironmentNames: environment.keys
                .filter { shouldIncludeValue(forEnvironmentName: $0) == false }
                .sorted()
        )
    }

    private static func inspectInitFile(
        shell: ShellDefinition,
        url: URL,
        homeURL: URL,
        fileManager: FileManager
    ) -> DiagnosticsShellInitFile {
        guard fileManager.fileExists(atPath: url.path) else {
            return DiagnosticsShellInitFile(
                name: shell.name,
                rcPath: url.path,
                exists: false,
                sourcingMarkerPresent: false,
                readError: nil
            )
        }

        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            let sourceLine = ToasttyShellIntegrationMarkers.sourceLine(
                managedSnippetFileName: shell.managedSnippetFileName
            )
            let markers = ToasttyShellIntegrationMarkers.referenceMarkers(
                managedSnippetPath: homeURL
                    .appendingPathComponent(
                        ToasttyShellIntegrationMarkers.managedSnippetRelativePath(
                            fileName: shell.managedSnippetFileName
                        ),
                        isDirectory: false
                    )
                    .path,
                managedSnippetFileName: shell.managedSnippetFileName,
                sourceLine: sourceLine
            )
            let present = contents
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false && $0.hasPrefix("#") == false }
                .contains { line in
                    markers.contains(where: line.contains)
                }
            return DiagnosticsShellInitFile(
                name: shell.name,
                rcPath: url.path,
                exists: true,
                sourcingMarkerPresent: present,
                readError: nil
            )
        } catch {
            return DiagnosticsShellInitFile(
                name: shell.name,
                rcPath: url.path,
                exists: true,
                sourcingMarkerPresent: false,
                readError: error.localizedDescription
            )
        }
    }

    private static func listDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> DiagnosticsDirectoryListing {
        guard fileManager.fileExists(atPath: url.path) else {
            return DiagnosticsDirectoryListing(
                path: url.path,
                exists: false,
                entries: [],
                readError: nil
            )
        }

        do {
            let entries = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            .map { entryURL in
                let values = try? entryURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                return DiagnosticsDirectoryEntry(
                    name: entryURL.lastPathComponent,
                    isDirectory: values?.isDirectory == true,
                    isExecutable: fileManager.isExecutableFile(atPath: entryURL.path),
                    sizeBytes: values?.fileSize.map(UInt64.init)
                )
            }
            .sorted { $0.name < $1.name }
            return DiagnosticsDirectoryListing(
                path: url.path,
                exists: true,
                entries: entries,
                readError: nil
            )
        } catch {
            return DiagnosticsDirectoryListing(
                path: url.path,
                exists: true,
                entries: [],
                readError: error.localizedDescription
            )
        }
    }

    private static func diagnosticEnvironmentEntries(
        _ environment: [String: String]
    ) -> [DiagnosticsEnvironmentEntry] {
        environment.keys
            .filter(shouldIncludeValue(forEnvironmentName:))
            .sorted()
            .map { name in
                DiagnosticsEnvironmentEntry(name: name, value: environment[name])
            }
    }

    private static func shouldIncludeValue(forEnvironmentName name: String) -> Bool {
        name.hasPrefix("TOASTTY_") || valueEnvironmentNames.contains(name)
    }
}

private enum DiagnosticsSystemCollector {
    static func collect() -> DiagnosticsSystemSection {
        DiagnosticsSystemSection(
            macosVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: sysctlString("hw.model"),
            arch: machineArchitecture()
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}

private enum DiagnosticsProbeCollector {
    static func collect(
        shellProbeFilePath: String?,
        fileManager: FileManager
    ) -> DiagnosticsProbeSection {
        guard let shellProbeFilePath, shellProbeFilePath.isEmpty == false else {
            return DiagnosticsProbeSection(shellProbePath: nil, rawShellProbe: nil, readError: nil)
        }

        guard fileManager.fileExists(atPath: shellProbeFilePath) else {
            return DiagnosticsProbeSection(
                shellProbePath: shellProbeFilePath,
                rawShellProbe: nil,
                readError: "shell probe file not found"
            )
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: shellProbeFilePath, isDirectory: false))
            return DiagnosticsProbeSection(
                shellProbePath: shellProbeFilePath,
                rawShellProbe: String(decoding: data, as: UTF8.self),
                readError: nil
            )
        } catch {
            return DiagnosticsProbeSection(
                shellProbePath: shellProbeFilePath,
                rawShellProbe: nil,
                readError: error.localizedDescription
            )
        }
    }
}

private func millisecondsSinceEpoch(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
}

private func isProcessAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 {
        return true
    }
    return errno == EPERM
}
