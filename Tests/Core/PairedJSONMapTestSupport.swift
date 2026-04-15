import Foundation

struct PairedJSONMapError: Error {
    let message: String
}

func decodePairedJSONMap(_ value: Any?, label: String) throws -> [String: Any] {
    guard let entries = value as? [Any] else {
        let message = "Expected \(label) to encode as a paired key/value array."
        throw PairedJSONMapError(message: message)
    }

    guard entries.count.isMultiple(of: 2) else {
        let message = "Expected \(label) paired array to contain an even number of elements."
        throw PairedJSONMapError(message: message)
    }

    var result: [String: Any] = [:]
    var index = 0
    while index < entries.count {
        guard let key = entries[index] as? String else {
            let message = "Expected \(label) key at index \(index) to be a String."
            throw PairedJSONMapError(message: message)
        }

        result[key] = entries[index + 1]
        index += 2
    }

    return result
}

func encodePairedJSONMap(_ value: [String: Any]) -> [Any] {
    value.keys.sorted().flatMap { key in
        [key, value[key] as Any]
    }
}
