import Foundation

public enum SocketEventNormalizationError: Error, Equatable, Sendable {
    case missingCWDForRelativePath(String)
}

public enum SocketEventNormalizer {
    public static func normalizeFiles(_ files: [String], cwd: String?) throws -> [String] {
        var normalized: [String] = []
        normalized.reserveCapacity(files.count)

        for file in files {
            if file.hasPrefix("/") {
                normalized.append(URL(fileURLWithPath: file).standardizedFileURL.path)
                continue
            }

            guard let cwd else {
                throw SocketEventNormalizationError.missingCWDForRelativePath(file)
            }

            let absolute = URL(fileURLWithPath: file, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true))
                .standardizedFileURL
                .path
            normalized.append(absolute)
        }

        return normalized
    }
}
