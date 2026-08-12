import Foundation

/// Pinned JSON coding for every remote-access wire type.
///
/// The gateway and all clients must use these (or byte-compatible) settings:
/// ISO 8601 timestamps with fractional seconds and sorted object keys, so the
/// same value always encodes to the same bytes regardless of process or
/// encoder instance.
public enum ConversationEventCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(fractionalSecondsStyle))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? Date(string, strategy: fractionalSecondsStyle) {
                return date
            }
            if let date = try? Date(string, strategy: wholeSecondsStyle) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 timestamp: \(string)"
            )
        }
        return decoder
    }

    private static let fractionalSecondsStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondsStyle = Date.ISO8601FormatStyle()
}
