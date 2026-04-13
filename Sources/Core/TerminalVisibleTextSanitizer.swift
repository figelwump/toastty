import Foundation

public enum TerminalVisibleTextSanitizer {
    public static func sanitizedLines(_ visibleText: String) -> [String] {
        let filteredScalars = visibleText.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x0A, 0x0D:
                return true
            default:
                return scalar.value >= 0x20 && scalar.value != 0x7F
            }
        }
        let sanitized = String(String.UnicodeScalarView(filteredScalars))
        return sanitized
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }
}
