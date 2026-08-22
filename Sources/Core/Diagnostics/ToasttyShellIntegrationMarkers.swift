import Foundation

public enum ToasttyShellIntegrationMarkers {
    public static let runtimeMarkerEnvironmentName = "TOASTTY_SHELL_INTEGRATION"
    public static let runtimeMarkerSchemaVersion = 1

    public static let managedSourceCommentLines = [
        "# Added by Toastty terminal profile shell integration",
        "# Keep this near the end of this file, after other PATH, history, and prompt-hook changes,",
        "# so Toastty can restore its shim directory and prompt-time title/journal hooks.",
    ]

    public static func managedSnippetRelativePath(fileName: String) -> String {
        ".toastty/shell/\(fileName)"
    }

    public static func sourceLine(managedSnippetFileName: String) -> String {
        "source \"$HOME/\(managedSnippetRelativePath(fileName: managedSnippetFileName))\""
    }

    public static func referenceMarkers(
        managedSnippetPath: String,
        managedSnippetFileName: String,
        sourceLine: String
    ) -> [String] {
        [
            sourceLine,
            managedSnippetPath,
            "$HOME/.toastty/shell/\(managedSnippetFileName)",
            "~/.toastty/shell/\(managedSnippetFileName)",
        ]
    }

    public static func parseRuntimeMarker(_ value: String) -> RuntimeMarkerParseResult {
        guard value.utf8.count <= 512 else {
            return .malformed
        }

        var fields: [String: String] = [:]
        for component in value.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else {
                return .malformed
            }
            let key = String(pair[0])
            let fieldValue = String(pair[1])
            guard key.isEmpty == false, fieldValue.isEmpty == false, fields[key] == nil else {
                return .malformed
            }
            fields[key] = fieldValue
        }

        guard let versionValue = fields["version"], let version = Int(versionValue), version > 0 else {
            return .malformed
        }
        guard version == runtimeMarkerSchemaVersion else {
            return .unsupportedVersion(version)
        }
        guard
            let shellValue = fields["shell"],
            let shell = RuntimeShell(rawValue: shellValue),
            let processIDValue = fields["pid"],
            let shellProcessID = Int32(processIDValue),
            shellProcessID > 0
        else {
            return .malformed
        }

        return .valid(
            RuntimeMarker(
                schemaVersion: version,
                shell: shell,
                shellProcessID: shellProcessID
            )
        )
    }

    public enum RuntimeShell: String, Equatable, Sendable {
        case zsh
        case bash
        case fish

        public var displayName: String {
            switch self {
            case .zsh: "Zsh"
            case .bash: "Bash"
            case .fish: "Fish"
            }
        }
    }

    public struct RuntimeMarker: Equatable, Sendable {
        public let schemaVersion: Int
        public let shell: RuntimeShell
        public let shellProcessID: Int32

        public init(
            schemaVersion: Int,
            shell: RuntimeShell,
            shellProcessID: Int32
        ) {
            self.schemaVersion = schemaVersion
            self.shell = shell
            self.shellProcessID = shellProcessID
        }
    }

    public enum RuntimeMarkerParseResult: Equatable, Sendable {
        case valid(RuntimeMarker)
        case unsupportedVersion(Int)
        case malformed
    }
}
