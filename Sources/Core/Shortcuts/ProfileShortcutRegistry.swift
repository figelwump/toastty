import Foundation

public struct ShortcutModifierSet: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)
}

public struct ShortcutChord: Hashable, Sendable {
    public let key: Character
    public let modifiers: ShortcutModifierSet

    public init(key: Character, modifiers: ShortcutModifierSet) {
        self.key = key
        self.modifiers = modifiers
    }

    public var symbolLabel: String {
        "\(modifiers.symbolLabel)\(String(key).uppercased())"
    }
}

public enum ProfileShortcutActionID: Hashable, Sendable {
    case terminalProfileSplit(profileID: String, direction: SlotSplitDirection)
    case agentProfileLaunch(profileID: String)
}

public enum ProfileShortcutDomain: String, Hashable, Sendable {
    case terminalProfile
    case agentProfile

    var displayName: String {
        switch self {
        case .terminalProfile:
            return "terminal profile"
        case .agentProfile:
            return "agent profile"
        }
    }
}

public struct ProfileShortcutSource: Hashable, Sendable {
    public let domain: ProfileShortcutDomain
    public let profileID: String
    public let filePath: String

    public init(
        domain: ProfileShortcutDomain,
        profileID: String,
        filePath: String
    ) {
        self.domain = domain
        self.profileID = profileID
        self.filePath = filePath
    }

    public var displayLabel: String {
        "\(domain.displayName) [\(profileID)]"
    }

    public var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

public struct ProfileShortcutConflict: Hashable, Sendable {
    public let chord: ShortcutChord
    public let sources: [ProfileShortcutSource]

    public init(chord: ShortcutChord, sources: [ProfileShortcutSource]) {
        self.chord = chord
        self.sources = sources
    }

    public var warningMessage: String {
        let sortedSources = sources.sorted {
            ($0.domain.rawValue, $0.profileID, $0.filePath) < ($1.domain.rawValue, $1.profileID, $1.filePath)
        }
        let contenders = sortedSources.map {
            "\($0.displayLabel) (\($0.fileName))"
        }.joined(separator: " and ")
        return "Disabled \(chord.symbolLabel) because it is assigned to \(contenders)."
    }
}

public struct ProfileShortcutRegistry: Equatable, Sendable {
    public let chordByActionID: [ProfileShortcutActionID: ShortcutChord]
    public let conflicts: [ProfileShortcutConflict]

    public init(
        terminalProfiles: TerminalProfileCatalog,
        terminalProfilesFilePath: String,
        agentProfiles: AgentCatalog,
        agentProfilesFilePath: String,
        terminalSplitBaseModifiers: ShortcutModifierSet = [.command, .option],
        agentShortcutModifiers: ShortcutModifierSet = [.command, .option]
    ) {
        struct Candidate: Hashable {
            let actionID: ProfileShortcutActionID
            let source: ProfileShortcutSource
        }

        var candidatesByChord: [ShortcutChord: [Candidate]] = [:]

        func append(
            chord: ShortcutChord,
            actionID: ProfileShortcutActionID,
            source: ProfileShortcutSource
        ) {
            candidatesByChord[chord, default: []].append(
                Candidate(actionID: actionID, source: source)
            )
        }

        for profile in terminalProfiles.profiles {
            guard let shortcutKey = profile.shortcutKey else { continue }

            let source = ProfileShortcutSource(
                domain: .terminalProfile,
                profileID: profile.id,
                filePath: terminalProfilesFilePath
            )
            append(
                chord: ShortcutChord(key: shortcutKey, modifiers: terminalSplitBaseModifiers),
                actionID: .terminalProfileSplit(profileID: profile.id, direction: .right),
                source: source
            )
            append(
                chord: ShortcutChord(
                    key: shortcutKey,
                    modifiers: terminalSplitBaseModifiers.union(.shift)
                ),
                actionID: .terminalProfileSplit(profileID: profile.id, direction: .down),
                source: source
            )
        }

        for profile in agentProfiles.profiles {
            guard let shortcutKey = profile.shortcutKey else { continue }

            append(
                chord: ShortcutChord(key: shortcutKey, modifiers: agentShortcutModifiers),
                actionID: .agentProfileLaunch(profileID: profile.id),
                source: ProfileShortcutSource(
                    domain: .agentProfile,
                    profileID: profile.id,
                    filePath: agentProfilesFilePath
                )
            )
        }

        var chordByActionID: [ProfileShortcutActionID: ShortcutChord] = [:]
        var conflicts: [ProfileShortcutConflict] = []

        for chord in candidatesByChord.keys.sorted(by: Self.compareChord) {
            guard let candidates = candidatesByChord[chord] else { continue }

            if candidates.count == 1, let candidate = candidates.first {
                chordByActionID[candidate.actionID] = chord
                continue
            }

            conflicts.append(
                ProfileShortcutConflict(
                    chord: chord,
                    sources: candidates.map(\.source)
                )
            )
        }

        self.chordByActionID = chordByActionID
        self.conflicts = conflicts
    }

    public func chord(for actionID: ProfileShortcutActionID) -> ShortcutChord? {
        chordByActionID[actionID]
    }

    public var warningMessages: [String] {
        conflicts.map(\.warningMessage)
    }

    private static func compareChord(_ lhs: ShortcutChord, _ rhs: ShortcutChord) -> Bool {
        if lhs.modifiers.rawValue != rhs.modifiers.rawValue {
            return lhs.modifiers.rawValue < rhs.modifiers.rawValue
        }
        return String(lhs.key) < String(rhs.key)
    }
}

private extension ShortcutModifierSet {
    var symbolLabel: String {
        var label = ""
        if contains(.control) {
            label += "⌃"
        }
        if contains(.option) {
            label += "⌥"
        }
        if contains(.shift) {
            label += "⇧"
        }
        if contains(.command) {
            label += "⌘"
        }
        return label
    }
}
