import Foundation

public enum TerminalDropPayloadBuilder {
    public static func shellEscapedPathPayload(
        forFilePaths filePaths: [String],
        appendTrailingSpace: Bool = true
    ) -> String? {
        guard filePaths.isEmpty == false else { return nil }
        guard filePaths.allSatisfy({ containsLineBreak($0) == false }) else {
            return nil
        }
        let escapedPaths = filePaths.map(shellEscapedPath)
        let payload = escapedPaths.joined(separator: " ")
        if appendTrailingSpace {
            return payload + " "
        }
        return payload
    }

    public static func shellEscapedPath(_ path: String) -> String {
        guard path.isEmpty == false else {
            return "''"
        }

        var escaped = "'"
        for character in path {
            if character == "'" {
                escaped.append("'\"'\"'")
            } else {
                escaped.append(character)
            }
        }
        escaped.append("'")
        return escaped
    }

    private static func containsLineBreak(_ path: String) -> Bool {
        path.contains("\n") || path.contains("\r")
    }
}
