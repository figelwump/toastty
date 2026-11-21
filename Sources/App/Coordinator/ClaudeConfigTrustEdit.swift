import Foundation

/// Sets `projects["<folder>"].hasTrustDialogAccepted` to `true` in the text
/// of Claude Code's config file, as Claude Code's own folder-trust dialog
/// does, and changes no other byte.
///
/// The file is Claude Code's, and holds much more than folder trust. So the
/// edit does not decode and encode the document: that would reorder its keys
/// and rewrite its numbers. It finds the one place in the text and inserts
/// or replaces there. The result is then checked against the document that
/// was read, and an edit that changed anything else is refused.
enum ClaudeConfigTrustEdit {
    static let projectsKey = "projects"
    static let trustKey = "hasTrustDialogAccepted"

    enum Result: Equatable {
        /// The folder is trusted already: there is nothing to write.
        case alreadyTrusted
        case edited(Data)
    }

    struct Failure: Error, Equatable, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    static func trusting(folderKey: String, in data: Data) throws -> Result {
        let bytes = [UInt8](data)
        var scanner = Scanner(bytes: bytes)
        let root = try scanner.rootObject()
        let edit: Edit
        if let projects = try root.member(projectsKey, in: bytes) {
            let projectsObject = try scanner.object(at: projects.value, named: "projects")
            if let entry = try projectsObject.member(folderKey, in: bytes) {
                let entryObject = try scanner.object(at: entry.value, named: "the folder's entry")
                if let trust = try entryObject.member(trustKey, in: bytes) {
                    if bytes[trust.value].elementsEqual("true".utf8) { return .alreadyTrusted }
                    edit = Edit(range: trust.value, text: "true")
                } else {
                    edit = entryObject.insertion(of: member(trustKey, "true"), in: bytes)
                }
            } else {
                edit = projectsObject.insertion(of: member(folderKey, trustedEntry), in: bytes)
            }
        } else {
            edit = root.insertion(of: member(projectsKey, "{\(member(folderKey, trustedEntry))}"), in: bytes)
        }
        var edited = bytes
        edited.replaceSubrange(edit.range, with: Array(edit.text.utf8))
        let result = Data(edited)
        try verify(result, trusts: folderKey, andKeepsTheRestOf: data)
        return .edited(result)
    }

    private static let trustedEntry = "{\(member(trustKey, "true"))}"

    private static func member(_ key: String, _ value: String) -> String {
        "\(quoted(key)): \(value)"
    }

    /// A JSON string as `JSON.stringify` writes it: only the quote, the
    /// backslash and control characters are escaped.
    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    // MARK: - Check

    /// The edited text must be the document that was read, with the one
    /// folder trusted and nothing else different.
    private static func verify(_ edited: Data, trusts folderKey: String, andKeepsTheRestOf original: Data) throws {
        guard let before = try? JSONSerialization.jsonObject(with: original) as? NSDictionary,
              let after = try? JSONSerialization.jsonObject(with: edited) as? NSDictionary else {
            throw Failure(reason: "the config file is not a JSON object")
        }
        let key = folderKey as NSString
        let projects = NSMutableDictionary(dictionary: (before[projectsKey] as? NSDictionary) ?? [:])
        let entry = NSMutableDictionary(dictionary: (projects[key] as? NSDictionary) ?? [:])
        entry[trustKey] = true
        projects[key] = entry
        let expected = NSMutableDictionary(dictionary: before)
        expected[projectsKey] = projects
        // Compared as Foundation holds them: a Swift dictionary would take
        // two keys that differ only in Unicode normalization for one.
        let written = ((after[projectsKey] as? NSDictionary)?[key] as? NSDictionary)?[trustKey] as? NSNumber
        guard expected.isEqual(after),
              let written, CFGetTypeID(written) == CFBooleanGetTypeID(), written.boolValue else {
            throw Failure(reason: "the edit would change more than the folder's trust")
        }
    }

    // MARK: - The text

    private struct Edit {
        var range: Range<Int>
        var text: String
    }

    private struct Member {
        /// The key's text with its quotes.
        var key: Range<Int>
        var value: Range<Int>
    }

    /// One object of the document: where its braces are and where each of
    /// its members is.
    private struct Object {
        var open: Int
        var close: Int
        var members: [Member]

        /// The member with this key. A key that is there twice has no one
        /// value, so the edit stops.
        func member(_ name: String, in bytes: [UInt8]) throws -> Member? {
            let wanted = Array(name.utf8)
            let found = try members.filter { member in
                let token = Data(bytes[member.key])
                guard let key = try JSONSerialization.jsonObject(with: token, options: .fragmentsAllowed) as? String else {
                    throw Failure(reason: "a key of the config file is not a string")
                }
                // Byte for byte: Claude Code compares keys without Unicode
                // normalization.
                return Array(key.utf8) == wanted
            }
            guard found.count <= 1 else {
                throw Failure(reason: "the config file has the key \(name) twice")
            }
            return found.first
        }

        /// Adds a member after the last one, with the space the last one
        /// has in front of it, so the file keeps its layout.
        func insertion(of text: String, in bytes: [UInt8]) -> Edit {
            guard let last = members.last else {
                return Edit(range: (open + 1) ..< (open + 1), text: text)
            }
            var start = last.key.lowerBound
            while start > open + 1, Scanner.isWhitespace(bytes[start - 1]) { start -= 1 }
            let space = String(decoding: bytes[start ..< last.key.lowerBound], as: UTF8.self)
            return Edit(range: last.value.upperBound ..< last.value.upperBound, text: "," + space + text)
        }
    }

    /// Walks JSON text and reports where things are. It reads no values.
    private struct Scanner {
        let bytes: [UInt8]
        private var index = 0
        private static let maximumDepth = 256

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
        }

        /// The document's one value, which must be an object.
        mutating func rootObject() throws -> Object {
            index = 0
            skipWhitespace()
            let object = try scanObject(depth: 0)
            skipWhitespace()
            guard index == bytes.count else { throw Failure(reason: "the config file has text after its object") }
            return object
        }

        /// The object that fills `range`.
        mutating func object(at range: Range<Int>, named name: String) throws -> Object {
            guard range.isEmpty == false, bytes[range.lowerBound] == UInt8(ascii: "{") else {
                throw Failure(reason: "\(name) is not an object in the config file")
            }
            index = range.lowerBound
            return try scanObject(depth: 0)
        }

        private mutating func skipWhitespace() {
            while index < bytes.count, Self.isWhitespace(bytes[index]) { index += 1 }
        }

        private func peek() throws -> UInt8 {
            guard index < bytes.count else { throw Failure(reason: "the config file ends early") }
            return bytes[index]
        }

        private mutating func expect(_ character: Character) throws {
            guard try peek() == character.asciiValue else {
                throw Failure(reason: "the config file is not valid JSON at byte \(index)")
            }
            index += 1
        }

        private mutating func scanObject(depth: Int) throws -> Object {
            guard depth < Self.maximumDepth else { throw Failure(reason: "the config file nests too deep") }
            let open = index
            try expect("{")
            var members: [Member] = []
            skipWhitespace()
            if try peek() == UInt8(ascii: "}") {
                index += 1
                return Object(open: open, close: index - 1, members: members)
            }
            while true {
                skipWhitespace()
                let key = try scanString()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                let value = try scanValue(depth: depth + 1)
                members.append(Member(key: key, value: value))
                skipWhitespace()
                if try peek() == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                try expect("}")
                return Object(open: open, close: index - 1, members: members)
            }
        }

        private mutating func scanArray(depth: Int) throws {
            guard depth < Self.maximumDepth else { throw Failure(reason: "the config file nests too deep") }
            try expect("[")
            skipWhitespace()
            if try peek() == UInt8(ascii: "]") {
                index += 1
                return
            }
            while true {
                skipWhitespace()
                _ = try scanValue(depth: depth + 1)
                skipWhitespace()
                if try peek() == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                try expect("]")
                return
            }
        }

        private mutating func scanValue(depth: Int) throws -> Range<Int> {
            let start = index
            switch try peek() {
            case UInt8(ascii: "{"):
                _ = try scanObject(depth: depth)
            case UInt8(ascii: "["):
                try scanArray(depth: depth)
            case UInt8(ascii: "\""):
                _ = try scanString()
            default:
                // A number, `true`, `false` or `null`: up to the next
                // separator. The check after the edit reads its value.
                while index < bytes.count,
                      Self.isWhitespace(bytes[index]) == false,
                      bytes[index] != UInt8(ascii: ","),
                      bytes[index] != UInt8(ascii: "}"),
                      bytes[index] != UInt8(ascii: "]") {
                    index += 1
                }
                guard index > start else { throw Failure(reason: "the config file is not valid JSON at byte \(index)") }
            }
            return start ..< index
        }

        private mutating func scanString() throws -> Range<Int> {
            let start = index
            try expect("\"")
            while true {
                let byte = try peek()
                index += 1
                if byte == UInt8(ascii: "\\") {
                    _ = try peek()
                    index += 1
                } else if byte == UInt8(ascii: "\"") {
                    return start ..< index
                }
            }
        }
    }
}
