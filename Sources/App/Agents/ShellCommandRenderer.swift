import Foundation

enum ShellCommandRenderer {
    static func render(
        argv: [String],
        environment: [String: String] = [:]
    ) -> String {
        var command = environment
            .sorted(by: { $0.key < $1.key })
            .map { assignment($0.key, $0.value) }

        command.append(contentsOf: argv.map(quote))
        return command.joined(separator: " ")
    }

    private static func quote(_ value: String) -> String {
        guard value.isEmpty == false else { return "''" }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789%+,-./:=@_")
        if value.unicodeScalars.allSatisfy(allowed.contains) {
            return value
        }

        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private static func assignment(_ key: String, _ value: String) -> String {
        "\(key)=\(quote(value))"
    }
}
