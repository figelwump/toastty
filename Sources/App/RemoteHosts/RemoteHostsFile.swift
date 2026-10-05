import CoreState
import Foundation
import ToasttyMobileDomain

/// One other Mac whose Toastty sessions this Mac lists in its sidebar.
struct RemoteHostConfiguration: Equatable, Sendable, Identifiable {
    /// The table name in `remotes.toml`. It appears in commands typed into a
    /// local shell, so it is limited to letters, digits, `.`, `_`, and `-`.
    let id: String
    let displayName: String
    /// The host's Tailscale Serve origin, in the canonical form pairing uses.
    let gatewayURL: URL
    /// What `ssh` connects to: a host alias, or `user@host`.
    let sshDestination: String
}

struct RemoteHostsParseError: LocalizedError, Equatable, Sendable {
    let line: Int
    let message: String

    var errorDescription: String? {
        "remotes.toml line \(line): \(message)"
    }
}

enum RemoteHostsFile {
    static let environmentOverrideKey = "TOASTTY_REMOTE_HOSTS_PATH"

    static func fileURL(
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let overrideURL = overrideFileURL(environment: environment) {
            return overrideURL
        }
        return ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        ).remoteHostsFileURL
    }

    private static func overrideFileURL(environment: [String: String]) -> URL? {
        guard let rawOverridePath = environment[environmentOverrideKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              rawOverridePath.isEmpty == false else {
            return nil
        }
        return URL(filePath: (rawOverridePath as NSString).expandingTildeInPath)
    }

    static func ensureTemplateExists(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        // An override path is for tests and automation; do not create files
        // outside the standard Toastty config location.
        if overrideFileURL(environment: environment) != nil {
            return
        }
        let url = fileURL(homeDirectoryPath: homeDirectoryPath, environment: environment)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try Data(templateContents().utf8).write(to: url, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return
        }
    }

    static func load(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [RemoteHostConfiguration] {
        let url = fileURL(homeDirectoryPath: homeDirectoryPath, environment: environment)
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        return try parse(contents: String(contentsOf: url, encoding: .utf8))
    }

    static func templateContents() -> String {
        """
        # Toastty remote hosts
        #
        # Each table names another Mac that runs Toastty with Remote Access
        # enabled. Toastty lists that Mac's agent sessions in the sidebar and
        # opens a session by attaching a terminal to it over SSH.
        # See docs/remote-access.md for the setup on both Macs.
        #
        # `gatewayURL` is the other Mac's Tailscale Serve address.
        # `sshDestination` is what you pass to `ssh`: a host alias or user@host.
        # `displayName` (optional) is the sidebar label. The default is the
        # table name.
        #
        # After editing, choose Toastty > Reload Configuration, then pair from
        # the remote's menu in the sidebar.
        #
        # [mini]
        # displayName = "Mini"
        # gatewayURL = "https://mini.your-tailnet.ts.net"
        # sshDestination = "mini"
        """
            + "\n"
    }

    // MARK: - Parsing

    private struct PartialHost {
        var line: Int
        var values: [String: String] = [:]
    }

    private static let knownKeys: Set<String> = ["displayName", "gatewayURL", "sshDestination"]

    static func parse(contents: String) throws -> [RemoteHostConfiguration] {
        var hosts: [RemoteHostConfiguration] = []
        var currentID: String?
        var current: PartialHost?
        var seenIDs = Set<String>()

        func finalizeCurrent() throws {
            guard let currentID, let current else { return }
            hosts.append(try makeHost(id: currentID, partial: current))
        }

        for (index, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let line = index + 1
            let trimmedLine = stripComment(from: rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.isEmpty == false else { continue }

            if trimmedLine.hasPrefix("[") {
                guard trimmedLine.hasSuffix("]") else {
                    throw RemoteHostsParseError(line: line, message: "invalid table header")
                }
                try finalizeCurrent()
                let rawID = String(trimmedLine.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard isValidHostID(rawID) else {
                    throw RemoteHostsParseError(
                        line: line,
                        message: "invalid remote ID '\(rawID)'; use letters, digits, '.', '_', and '-'"
                    )
                }
                guard seenIDs.insert(rawID).inserted else {
                    throw RemoteHostsParseError(line: line, message: "duplicate remote '\(rawID)'")
                }
                currentID = rawID
                current = PartialHost(line: line)
                continue
            }

            guard let currentID else {
                throw RemoteHostsParseError(line: line, message: "expected [remote-id] table before fields")
            }
            guard let equalsIndex = trimmedLine.firstIndex(of: "=") else {
                throw RemoteHostsParseError(line: line, message: "expected key = value")
            }
            let key = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = trimmedLine[trimmedLine.index(after: equalsIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard knownKeys.contains(key) else {
                throw RemoteHostsParseError(line: line, message: "[\(currentID)] contains unknown key '\(key)'")
            }
            guard current?.values[key] == nil else {
                throw RemoteHostsParseError(line: line, message: "[\(currentID)] has duplicate \(key)")
            }
            guard let value = try? JSONDecoder().decode(String.self, from: Data(rawValue.utf8)) else {
                throw RemoteHostsParseError(line: line, message: "[\(currentID)] has invalid \(key)")
            }
            current?.values[key] = value
        }

        try finalizeCurrent()
        return hosts
    }

    private static func makeHost(id: String, partial: PartialHost) throws -> RemoteHostConfiguration {
        func value(_ key: String) -> String? {
            guard let trimmed = partial.values[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  trimmed.isEmpty == false else { return nil }
            return trimmed
        }
        guard let rawGatewayURL = value("gatewayURL") else {
            throw RemoteHostsParseError(line: partial.line, message: "[\(id)] is missing gatewayURL")
        }
        // The same rule pairing applies, so a URL accepted here can pair.
        guard let gatewayURL = try? PairingInputParser.canonicalGatewayURL(rawGatewayURL) else {
            throw RemoteHostsParseError(
                line: partial.line,
                message: "[\(id)] gatewayURL must be an https://<name>.ts.net address without a path or port"
            )
        }
        guard let sshDestination = value("sshDestination") else {
            throw RemoteHostsParseError(line: partial.line, message: "[\(id)] is missing sshDestination")
        }
        guard isValidSSHDestination(sshDestination) else {
            throw RemoteHostsParseError(
                line: partial.line,
                message: "[\(id)] sshDestination must be a host alias or user@host without spaces"
            )
        }
        let displayName = value("displayName") ?? id
        guard displayName.count <= 60,
              displayName.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) == false }) else {
            throw RemoteHostsParseError(line: partial.line, message: "[\(id)] has invalid displayName")
        }
        return RemoteHostConfiguration(
            id: id,
            displayName: displayName,
            gatewayURL: gatewayURL,
            sshDestination: sshDestination
        )
    }

    static func isValidHostID(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.isEmpty == false
            && value.count <= 64
            && value.hasPrefix("-") == false
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// `ssh` receives the destination as its own argument, after `--`, so no
    /// shell reads it. The leading-dash rule still keeps it from being taken
    /// for an option by a wrapper that omits the `--`.
    static func isValidSSHDestination(_ value: String) -> Bool {
        value.isEmpty == false
            && value.utf8.count <= 255
            && value.hasPrefix("-") == false
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && CharacterSet.whitespacesAndNewlines.contains(scalar) == false
                    && CharacterSet.controlCharacters.contains(scalar) == false
            }
    }

    private static func stripComment(from line: String) -> String {
        var result = ""
        var isInsideString = false
        var isEscaping = false
        for character in line {
            if isEscaping {
                result.append(character)
                isEscaping = false
                continue
            }
            if character == "\\" {
                result.append(character)
                isEscaping = isInsideString
                continue
            }
            if character == "\"" {
                isInsideString.toggle()
            } else if character == "#", isInsideString == false {
                break
            }
            result.append(character)
        }
        return result
    }
}
