import AppKit
import CoreState
import Foundation

struct BrowserPanelScreenshot: Equatable {
    var pngData: Data
    var suggestedFileName: String
}

enum BrowserPanelScreenshotError: LocalizedError, Equatable {
    case emptySnapshotBounds
    case snapshotUnavailable
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .emptySnapshotBounds:
            return "browser panel has no visible area to capture"
        case .snapshotUnavailable:
            return "browser panel snapshot is unavailable"
        case .pngEncodingFailed:
            return "failed to encode browser screenshot as PNG"
        }
    }
}

struct BrowserScreenshotSendCandidate: Equatable, Identifiable {
    let sessionID: String
    let agent: AgentKind
    let panelID: UUID
    let label: String

    var id: String { sessionID }
}

enum BrowserScreenshotSendCandidateBuilder {
    static func candidates(
        workspace: WorkspaceState,
        browserPanelID: UUID,
        sessionRegistry: SessionRegistry
    ) -> [BrowserScreenshotSendCandidate] {
        guard let ownerTabID = workspace.tabID(containingPanelID: browserPanelID)
                ?? workspace.rightAuxPanelTabLocation(containingPanelID: browserPanelID)?.mainTabID,
              let ownerTab = workspace.tab(id: ownerTabID),
              case .web(let webState) = workspace.panelState(for: browserPanelID),
              webState.definition == .browser else {
            return []
        }

        return candidates(workspaceTab: ownerTab, sessionRegistry: sessionRegistry)
    }

    static func candidates(
        workspaceTab: WorkspaceTabState,
        sessionRegistry: SessionRegistry
    ) -> [BrowserScreenshotSendCandidate] {
        ScratchpadAgentBindCandidateBuilder.candidates(
            workspaceTab: workspaceTab,
            sessionRegistry: sessionRegistry,
            currentSessionID: nil
        )
        .map { candidate in
            BrowserScreenshotSendCandidate(
                sessionID: candidate.sessionID,
                agent: candidate.agent,
                panelID: candidate.panelID,
                label: candidate.label
            )
        }
    }
}

enum BrowserPanelScreenshotWriter {
    private static let quickScreenshotDirectoryName = "toastty-browser-screenshots"
    private static let fallbackStem = "browser-screenshot"
    private static let maxStemLength = 80

    static func pngData(from image: NSImage) throws -> Data {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw BrowserPanelScreenshotError.pngEncodingFailed
        }
        return pngData
    }

    static func defaultQuickScreenshotDirectoryURL(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(
            quickScreenshotDirectoryName,
            isDirectory: true
        )
    }

    static func writeQuickScreenshot(
        pngData: Data,
        date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let directoryURL = defaultQuickScreenshotDirectoryURL(fileManager: fileManager)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let fileName = suggestedFileName(title: nil, urlString: nil, date: date)
        let targetURL = availableFileURL(
            for: fileName,
            in: directoryURL,
            fileManager: fileManager
        )
        try pngData.write(to: targetURL, options: [.atomic])
        return targetURL
    }

    static func suggestedFileName(
        title: String?,
        urlString: String?,
        date: Date = Date()
    ) -> String {
        let stem = suggestedFileNameStem(title: title, urlString: urlString)
        return "\(stem)-\(timestampComponent(for: date)).png"
    }

    static func suggestedFileNameStem(title: String?, urlString: String?) -> String {
        if let titleStem = sanitizedFileNameStem(title),
           titleStem.caseInsensitiveCompare(WebPanelDefinition.browser.defaultTitle) != .orderedSame {
            return titleStem
        }

        if let urlStem = urlDerivedStem(urlString: urlString) {
            return urlStem
        }

        return fallbackStem
    }

    static func sanitizedFileNameStem(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let allowedScalars = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._- "))
        let mapped = trimmed.unicodeScalars.map { scalar -> Character in
            allowedScalars.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "[\\s-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._ "))
        guard collapsed.isEmpty == false else { return nil }

        if collapsed.count <= maxStemLength {
            return collapsed
        }

        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: maxStemLength)
        return String(collapsed[..<endIndex]).trimmingCharacters(in: CharacterSet(charactersIn: "-._ "))
    }

    private static func urlDerivedStem(urlString: String?) -> String? {
        guard let urlString,
              let url = URL(string: urlString) else {
            return nil
        }

        if url.isFileURL {
            return sanitizedFileNameStem(url.deletingPathExtension().lastPathComponent)
        }

        let host = url.host(percentEncoded: false)
        let pathComponent = url.deletingPathExtension().lastPathComponent
        let rawStem = [host, pathComponent]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let trimmed, trimmed.isEmpty == false, trimmed != "/" else { return nil }
                return trimmed
            }
            .joined(separator: "-")
        return sanitizedFileNameStem(rawStem)
    }

    private static func timestampComponent(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func availableFileURL(
        for fileName: String,
        in directoryURL: URL,
        fileManager: FileManager
    ) -> URL {
        let baseURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let extensionName = baseURL.pathExtension
        let stem = baseURL.deletingPathExtension().lastPathComponent
        for index in 2 ... 999 {
            let candidate = directoryURL
                .appendingPathComponent("\(stem)-\(index)", isDirectory: false)
                .appendingPathExtension(extensionName)
            if fileManager.fileExists(atPath: candidate.path) == false {
                return candidate
            }
        }

        return directoryURL
            .appendingPathComponent("\(stem)-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension(extensionName)
    }
}

enum BrowserScreenshotAgentPromptBuilder {
    static func prompt(fileURL: URL) -> String {
        let filePath = fileURL.path(percentEncoded: false)
        return "Please inspect this browser screenshot at \"\(filePath)\"."
    }
}
