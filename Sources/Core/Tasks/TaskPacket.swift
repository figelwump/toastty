import Foundation

/// One version of a task's review packet: what the task's agent tells the
/// user to look at when its work is ready. The agent publishes it with
/// `toastty task packet publish`, and Toastty keeps it apart from the task
/// space, so it outlives the worktree.
///
/// On disk and on the wire the keys are snake case, as the agent writes
/// them: `summary`, `look_at`, `checks`, `not_verified`, `screenshots`.
/// Toastty adds `task_id`, `version`, `created_at` and `head_commit`.
public struct TaskPacket: Codable, Equatable, Sendable {
    public struct Check: Codable, Equatable, Sendable {
        public var name: String
        public var ok: Bool
        /// Where the output is, or a short excerpt of it.
        public var log: String?

        public init(name: String, ok: Bool, log: String? = nil) {
            self.name = name
            self.ok = ok
            self.log = log
        }
    }

    /// Which side of a before and after comparison a screenshot shows. A
    /// before and an after with the same width form a pair.
    public enum Pair: String, Codable, Equatable, Sendable, CaseIterable {
        case before
        case after
    }

    public struct Screenshot: Codable, Equatable, Sendable {
        /// The file's name without its extension. The agent passes a file
        /// with this name; Toastty stores it as `file`.
        public var name: String
        public var pair: Pair?
        /// The viewport width in points the screenshot was taken at.
        public var width: Int?
        /// The stored copy's file name, in the packet's directory. Set by
        /// Toastty when it stores the packet.
        public var file: String?

        public init(name: String, pair: Pair? = nil, width: Int? = nil, file: String? = nil) {
            self.name = name
            self.pair = pair
            self.width = width
            self.file = file
        }

        private enum CodingKeys: String, CodingKey {
            case name, pair, width, file
        }

        public func encode(to encoder: any Encoder) throws {
            // `pair` is written as null rather than left out, so a reader
            // sees the field the skill documents.
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(pair, forKey: .pair)
            try container.encode(width, forKey: .width)
            try container.encodeIfPresent(file, forKey: .file)
        }
    }

    /// What changed, in a line or two.
    public var summary: String
    /// The one specific thing the user should look at first.
    public var lookAt: String
    public var checks: [Check]
    /// What the agent did not check. An empty list is a claim that
    /// everything was checked, so the agent must write it out.
    public var notVerified: [String]
    public var screenshots: [Screenshot]
    public var taskID: UUID?
    public var version: Int?
    public var createdAt: Date?
    /// The worktree's commit when the packet was published; `nil` for a
    /// task without a worktree.
    public var headCommit: String?

    public init(
        summary: String,
        lookAt: String,
        checks: [Check] = [],
        notVerified: [String],
        screenshots: [Screenshot] = [],
        taskID: UUID? = nil,
        version: Int? = nil,
        createdAt: Date? = nil,
        headCommit: String? = nil
    ) {
        self.summary = summary
        self.lookAt = lookAt
        self.checks = checks
        self.notVerified = notVerified
        self.screenshots = screenshots
        self.taskID = taskID
        self.version = version
        self.createdAt = createdAt
        self.headCommit = headCommit
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case lookAt = "look_at"
        case checks
        case notVerified = "not_verified"
        case screenshots
        case taskID = "task_id"
        case version
        case createdAt = "created_at"
        case headCommit = "head_commit"
    }

    /// Whether commits landed in the worktree after the packet was
    /// published, so what it describes may no longer be what the user
    /// would review. Unknown commits never count as stale.
    public static func isStale(headCommit: String?, currentHead: String?) -> Bool {
        guard let headCommit, let currentHead else { return false }
        return headCommit != currentHead
    }
}

public struct TaskPacketError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public extension TaskRecord {
    /// Whether the newest packet is stale: the worktree's HEAD, read by the
    /// caller, moved past the commit it was published at.
    func packetIsStale(currentHead: String?) -> Bool {
        packetVersion != nil && TaskPacket.isStale(headCommit: packetHeadCommit, currentHead: currentHead)
    }
}

// MARK: - Validation

public extension TaskPacket {
    static let maximumTextLength = 4000
    static let maximumLogLength = 16 * 1024
    static let maximumCheckCount = 50
    static let maximumNotVerifiedCount = 50
    static let maximumScreenshotCount = 20
    static let maximumScreenshotBytes = 20 * 1024 * 1024
    static let maximumScreenshotNameLength = 64
    static let maximumWidth = 10000
    static let screenshotExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    /// Reads the JSON an agent wrote. Refuses a packet without `summary` or
    /// `look_at`, without `not_verified` (`[]` must be written out), with a
    /// key it does not know, or with a field of the wrong type. Toastty's
    /// own keys (`task_id`, `version`, `created_at`, `head_commit`) are
    /// refused too: Toastty sets them.
    static func parseDraft(_ data: Data) throws -> TaskPacket {
        guard let object = try? JSONSerialization.jsonObject(with: data), let fields = object as? [String: Any] else {
            throw TaskPacketError("The packet must be a JSON object.")
        }
        let known: Set<String> = ["summary", "look_at", "checks", "not_verified", "screenshots"]
        if let unknown = fields.keys.filter({ known.contains($0) == false }).sorted().first {
            throw TaskPacketError("The packet has an unknown key \"\(unknown)\"; expected \(known.sorted().joined(separator: ", ")).")
        }
        let summary = try requiredText(fields["summary"], key: "summary", maximum: maximumTextLength)
        let lookAt = try requiredText(fields["look_at"], key: "look_at", maximum: maximumTextLength)

        guard let rawNotVerified = fields["not_verified"] else {
            throw TaskPacketError("The packet needs not_verified: what you did not check, or [] when you checked everything.")
        }
        guard let notVerifiedItems = rawNotVerified as? [Any] else {
            throw TaskPacketError("not_verified must be a list of strings.")
        }
        guard notVerifiedItems.count <= maximumNotVerifiedCount else {
            throw TaskPacketError("not_verified has more than \(maximumNotVerifiedCount) items.")
        }
        let notVerified = try notVerifiedItems.map {
            try requiredText($0, key: "each not_verified item", maximum: maximumTextLength)
        }

        let checkItems = try list(fields["checks"], key: "checks", maximum: maximumCheckCount)
        let checks = try checkItems.map { item -> Check in
            guard let check = item as? [String: Any] else { throw TaskPacketError("Each check must be an object with name, ok and log.") }
            if let unknown = check.keys.filter({ ["name", "ok", "log"].contains($0) == false }).sorted().first {
                throw TaskPacketError("A check has an unknown key \"\(unknown)\"; expected name, ok, log.")
            }
            let name = try requiredText(check["name"], key: "check name", maximum: maximumTextLength)
            // JSONSerialization reads 1 and true alike; only a JSON boolean counts.
            guard let ok = check["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID() else {
                throw TaskPacketError("Check \"\(name)\" needs ok: true or false.")
            }
            let log = try optionalText(check["log"], key: "log of check \"\(name)\"", maximum: maximumLogLength)
            return Check(name: name, ok: ok.boolValue, log: log)
        }

        let screenshotItems = try list(fields["screenshots"], key: "screenshots", maximum: maximumScreenshotCount)
        var names: Set<String> = []
        let screenshots = try screenshotItems.map { item -> Screenshot in
            guard let shot = item as? [String: Any] else {
                throw TaskPacketError("Each screenshot must be an object with name, pair and width.")
            }
            if let unknown = shot.keys.filter({ ["name", "pair", "width"].contains($0) == false }).sorted().first {
                throw TaskPacketError("A screenshot has an unknown key \"\(unknown)\"; expected name, pair, width.")
            }
            guard let name = shot["name"] as? String, isValidScreenshotName(name) else {
                throw TaskPacketError(
                    "Each screenshot needs a name of letters, digits, '.', '_' or '-', at most \(maximumScreenshotNameLength) characters."
                )
            }
            guard names.insert(name).inserted else {
                throw TaskPacketError("Two screenshots are named \"\(name)\".")
            }
            var pair: Pair?
            if let rawPair = shot["pair"], rawPair is NSNull == false {
                guard let value = rawPair as? String, let parsed = Pair(rawValue: value) else {
                    throw TaskPacketError("Screenshot \"\(name)\" has pair \(rawPair); expected \"before\", \"after\" or null.")
                }
                pair = parsed
            }
            var width: Int?
            if let rawWidth = shot["width"], rawWidth is NSNull == false {
                guard let number = rawWidth as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let value = Int(exactly: number.doubleValue), (1...maximumWidth).contains(value) else {
                    throw TaskPacketError("Screenshot \"\(name)\" needs width as a whole number of points from 1 to \(maximumWidth).")
                }
                width = value
            }
            return Screenshot(name: name, pair: pair, width: width)
        }
        return TaskPacket(summary: summary, lookAt: lookAt, checks: checks, notVerified: notVerified, screenshots: screenshots)
    }

    /// The given file for each screenshot the packet names, matched on the
    /// file name without its extension. Every named screenshot needs a
    /// file, and every file must be named, so a typo fails here rather
    /// than leaving a picture out. `fileSize` returns `nil` for a path that
    /// is not a readable regular file.
    func matchScreenshots(files: [String], fileSize: (String) -> Int?) throws -> [(screenshot: Screenshot, path: String)] {
        var filesByName: [String: String] = [:]
        for path in files {
            let url = URL(filePath: path)
            let name = url.deletingPathExtension().lastPathComponent
            guard Self.screenshotExtensions.contains(url.pathExtension.lowercased()) else {
                throw TaskPacketError("Screenshot \(path) must be a \(Self.screenshotExtensions.sorted().joined(separator: ", ")) file.")
            }
            guard filesByName.updateValue(path, forKey: name) == nil else {
                throw TaskPacketError("Two screenshot files are named \(name).")
            }
        }
        var matched: [(screenshot: Screenshot, path: String)] = []
        for screenshot in screenshots {
            guard let path = filesByName.removeValue(forKey: screenshot.name) else {
                throw TaskPacketError("Screenshot \"\(screenshot.name)\" needs a file: pass --screenshot \(screenshot.name).png.")
            }
            guard let size = fileSize(path) else {
                throw TaskPacketError("Screenshot \(path) does not exist or is not a readable file.")
            }
            guard size <= Self.maximumScreenshotBytes else {
                throw TaskPacketError("Screenshot \(path) is larger than \(Self.maximumScreenshotBytes / 1024 / 1024) MB.")
            }
            matched.append((screenshot, path))
        }
        if let extra = filesByName.values.sorted().first {
            throw TaskPacketError("Screenshot \(extra) is not named in the packet's screenshots.")
        }
        return matched
    }

    static func isValidScreenshotName(_ name: String) -> Bool {
        guard name.isEmpty == false, name.count <= maximumScreenshotNameLength, name.hasPrefix(".") == false else { return false }
        return name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
        }
    }

    private static func requiredText(_ value: Any?, key: String, maximum: Int) throws -> String {
        guard let text = try optionalText(value, key: key, maximum: maximum) else {
            throw TaskPacketError("The packet needs \(key) as non-empty text.")
        }
        return text
    }

    private static func optionalText(_ value: Any?, key: String, maximum: Int) throws -> String? {
        guard let value, value is NSNull == false else { return nil }
        guard let text = value as? String else { throw TaskPacketError("\(key) must be text.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard trimmed.count <= maximum else { throw TaskPacketError("\(key) is longer than \(maximum) characters.") }
        return trimmed
    }

    private static func list(_ value: Any?, key: String, maximum: Int) throws -> [Any] {
        guard let value, value is NSNull == false else { return [] }
        guard let items = value as? [Any] else { throw TaskPacketError("\(key) must be a list.") }
        guard items.count <= maximum else { throw TaskPacketError("\(key) has more than \(maximum) items.") }
        return items
    }
}

// MARK: - Storage

/// Where packets live: `<root>/<task-id>/v<N>/packet.json`, with the
/// screenshots beside it. Versions start at 1 and never repeat.
public struct TaskPacketStore: Sendable {
    public static let packetFileName = "packet.json"

    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public func taskDirectoryURL(taskID: UUID) -> URL {
        rootURL.appending(path: taskID.uuidString, directoryHint: .isDirectory)
    }

    public func versionDirectoryURL(taskID: UUID, version: Int) -> URL {
        taskDirectoryURL(taskID: taskID).appending(path: "v\(version)", directoryHint: .isDirectory)
    }

    /// The versions stored for a task, lowest first.
    public func versions(taskID: UUID) -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: taskDirectoryURL(taskID: taskID).path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix("v"), let version = Int(name.dropFirst()), version > 0, "v\(version)" == name else { return nil }
            return version
        }.sorted()
    }

    /// Stores the packet as the next version after both `atLeastAfter` and
    /// every version on disk, and copies its screenshots beside it. The
    /// version's directory is made without intermediate directories, so
    /// two publishes at once cannot take the same number. Returns the
    /// stored packet, with `version` and each screenshot's `file` set.
    public func write(
        _ packet: TaskPacket,
        taskID: UUID,
        screenshots: [(screenshot: TaskPacket.Screenshot, path: String)],
        atLeastAfter recordedVersion: Int?
    ) throws -> TaskPacket {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: taskDirectoryURL(taskID: taskID), withIntermediateDirectories: true)
        var version = max(recordedVersion ?? 0, versions(taskID: taskID).last ?? 0) + 1
        var directoryURL = versionDirectoryURL(taskID: taskID, version: version)
        while true {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
                break
            } catch CocoaError.fileWriteFileExists {
                version += 1
                directoryURL = versionDirectoryURL(taskID: taskID, version: version)
            }
        }
        do {
            var stored = packet
            stored.taskID = taskID
            stored.version = version
            stored.screenshots = []
            for (screenshot, path) in screenshots {
                let fileName = screenshot.name + "." + URL(filePath: path).pathExtension.lowercased()
                try fileManager.copyItem(at: URL(filePath: path), to: directoryURL.appending(path: fileName, directoryHint: .notDirectory))
                var copy = screenshot
                copy.file = fileName
                stored.screenshots.append(copy)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(stored).write(
                to: directoryURL.appending(path: Self.packetFileName, directoryHint: .notDirectory),
                options: .atomic
            )
            return stored
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    /// The stored packet, or the newest one when `version` is `nil`.
    public func read(taskID: UUID, version: Int? = nil) throws -> TaskPacket {
        guard let version = version ?? versions(taskID: taskID).last else {
            throw TaskPacketError("The task has no packet.")
        }
        let url = versionDirectoryURL(taskID: taskID, version: version)
            .appending(path: Self.packetFileName, directoryHint: .notDirectory)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw TaskPacketError("The task has no packet v\(version).")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(TaskPacket.self, from: data)
        } catch {
            throw TaskPacketError("Packet v\(version) could not be read: \(error.localizedDescription)")
        }
    }
}
