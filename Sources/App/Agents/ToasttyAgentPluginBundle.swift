import CryptoKit
import Foundation

struct ToasttyAgentSkillDescriptor: Equatable, Sendable {
    let name: String
    let summary: String
}

struct ToasttyAgentPluginDescriptor: Equatable, Sendable {
    let name: String
    let version: String
    let pluginRootURL: URL
    let skillsRootURL: URL
    let skills: [ToasttyAgentSkillDescriptor]
    let contentDigest: String

    var skillNames: [String] {
        skills.map(\.name)
    }

    var qualifiedSkillNames: [String] {
        skillNames.map { "\(name):\($0)" }
    }
}

enum ToasttyAgentPluginBundle {
    static let pluginName = "toastty"
    static let skills = [
        ToasttyAgentSkillDescriptor(
            name: "toastty-capabilities",
            summary: "Control Toastty workspaces, panels, terminals, and managed agents."
        ),
        ToasttyAgentSkillDescriptor(
            name: "toastty-open-markdown",
            summary: "Open plans and Markdown files for review inside Toastty."
        ),
        ToasttyAgentSkillDescriptor(
            name: "toastty-scratchpad",
            summary: "Create and update visual diagrams, mockups, and summaries."
        ),
        ToasttyAgentSkillDescriptor(
            name: "worktree-create",
            summary: "Move work into an isolated Git worktree and Toastty workspace."
        ),
    ]

    static func bundledPluginURL(bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?
            .appendingPathComponent("ToasttyAgentPluginBundle/plugins/toastty", isDirectory: true)
    }

    static func read(
        pluginRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> ToasttyAgentPluginDescriptor {
        let resolvedRoot = pluginRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let codexManifestURL = resolvedRoot
            .appendingPathComponent(".codex-plugin", isDirectory: true)
            .appendingPathComponent("plugin.json", isDirectory: false)
        let claudeManifestURL = resolvedRoot
            .appendingPathComponent(".claude-plugin", isDirectory: true)
            .appendingPathComponent("plugin.json", isDirectory: false)

        let codexManifest: CodexManifest = try decodeManifest(at: codexManifestURL)
        let claudeManifest: ClaudeManifest = try decodeManifest(at: claudeManifestURL)
        guard codexManifest.name == pluginName,
              claudeManifest.name == pluginName,
              codexManifest.version == claudeManifest.version,
              normalizedVersion(codexManifest.version) != nil,
              codexManifest.skills == "./skills/" else {
            throw ToasttyAgentPluginBundleError.invalidManifest(codexManifestURL.path)
        }

        let skillsRootURL = resolvedRoot.appendingPathComponent("skills", isDirectory: true)
        let discoveredNames = try discoveredSkillNames(
            skillsRootURL: skillsRootURL,
            fileManager: fileManager
        )
        guard discoveredNames == skills.map(\.name).sorted() else {
            throw ToasttyAgentPluginBundleError.unexpectedSkills(discoveredNames)
        }

        return ToasttyAgentPluginDescriptor(
            name: pluginName,
            version: codexManifest.version,
            pluginRootURL: resolvedRoot,
            skillsRootURL: skillsRootURL,
            skills: skills,
            contentDigest: try contentDigest(rootURL: resolvedRoot, fileManager: fileManager)
        )
    }
}

enum ToasttyAgentPluginBundleError: LocalizedError, Equatable {
    case unreadableManifest(String)
    case invalidManifest(String)
    case unreadablePlugin(String)
    case symbolicLink(String)
    case invalidSkill(String)
    case unexpectedSkills([String])

    var errorDescription: String? {
        switch self {
        case .unreadableManifest(let path):
            return "Unable to read the Toastty agent plugin manifest at \(path)."
        case .invalidManifest(let path):
            return "The Toastty agent plugin manifest is invalid at \(path)."
        case .unreadablePlugin(let path):
            return "Unable to read the Toastty agent plugin at \(path)."
        case .symbolicLink(let path):
            return "The Toastty agent plugin contains an unsupported symbolic link at \(path)."
        case .invalidSkill(let path):
            return "The Toastty agent plugin contains an invalid skill at \(path)."
        case .unexpectedSkills(let names):
            return "The Toastty agent plugin contains an unexpected skill set: \(names.joined(separator: ", "))."
        }
    }
}

extension ToasttyAgentPluginBundle {
    /// Deterministic digest over every regular file under `rootURL`: sorted
    /// relative paths and file bytes, length-prefixed into SHA-256. Also used
    /// by `ToasttyUserSkillCatalog` to fingerprint generated `toastty-user`
    /// plugin roots for later cache verification.
    ///
    /// Deliberate asymmetry with `ToasttyUserSkillCatalog.sourceDigest`: this
    /// digest covers paths+bytes ONLY, excluding file modes, because staged
    /// and cached copies get their permissions normalized deterministically
    /// (script exec bits restored, everything else 0644) after every copy —
    /// mode is not part of plugin-content identity. The catalog's source
    /// digest additionally hashes the executable bit because a source
    /// exec-bit change alters delivered behavior and must produce a new
    /// snapshot. Do NOT change this algorithm: it would invalidate every
    /// existing receipt and cache.
    static func contentDigest(rootURL: URL, fileManager: FileManager) throws -> String {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw ToasttyAgentPluginBundleError.unreadablePlugin(rootURL.path)
        }

        var files: [(relativePath: String, url: URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ToasttyAgentPluginBundleError.symbolicLink(url.path)
            }
            if values.isRegularFile == true {
                let relativePath = url.pathComponents
                    .suffix(enumerator.level)
                    .joined(separator: "/")
                files.append((relativePath, url))
            } else if values.isDirectory != true {
                throw ToasttyAgentPluginBundleError.unreadablePlugin(url.path)
            }
        }

        var hasher = SHA256()
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            let data: Data
            do {
                data = try Data(contentsOf: file.url)
            } catch {
                throw ToasttyAgentPluginBundleError.unreadablePlugin(file.url.path)
            }
            hasher.update(data: Data("file:\(file.relativePath.utf8.count):\(file.relativePath):\(data.count):".utf8))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension ToasttyAgentPluginBundle {
    struct CodexManifest: Decodable {
        let name: String
        let version: String
        let skills: String
    }

    struct ClaudeManifest: Decodable {
        let name: String
        let version: String
    }

    static func decodeManifest<T: Decodable>(at url: URL) throws -> T {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ToasttyAgentPluginBundleError.unreadableManifest(url.path)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ToasttyAgentPluginBundleError.invalidManifest(url.path)
        }
    }

    static func normalizedVersion(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              trimmed.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    static func discoveredSkillNames(
        skillsRootURL: URL,
        fileManager: FileManager
    ) throws -> [String] {
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: skillsRootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ToasttyAgentPluginBundleError.unreadablePlugin(skillsRootURL.path)
        }

        var names: [String] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ToasttyAgentPluginBundleError.symbolicLink(child.path)
            }
            guard values.isDirectory == true else {
                throw ToasttyAgentPluginBundleError.invalidSkill(child.path)
            }
            let skillURL = child.appendingPathComponent("SKILL.md", isDirectory: false)
            guard let contents = try? String(contentsOf: skillURL, encoding: .utf8),
                  frontmatterName(in: contents) == child.lastPathComponent else {
                throw ToasttyAgentPluginBundleError.invalidSkill(skillURL.path)
            }
            names.append(child.lastPathComponent)
        }
        return names.sorted()
    }

    static func frontmatterName(in contents: String) -> String? {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return nil
        }
        for line in lines.dropFirst() {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "---" { return nil }
            guard line.first?.isWhitespace != true, text.hasPrefix("name:") else { continue }
            let rawValue = text.dropFirst("name:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if rawValue.count >= 2,
               let first = rawValue.first,
               let last = rawValue.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                return String(rawValue.dropFirst().dropLast())
            }
            return rawValue
        }
        return nil
    }
}
