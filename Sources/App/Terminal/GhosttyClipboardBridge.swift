#if TOASTTY_HAS_GHOSTTY_KIT
import AppKit
import GhosttyKit
import UniformTypeIdentifiers

// Values copied out of Ghostty callbacks own their bytes. C pointers are borrowed
// only within withCompletion, including a synchronous confirmation callback.
enum GhosttyClipboardBridge {
    struct Entry {
        let mime: String
        let data: Data
    }

    struct ReadContents {
        let contents: [Entry]
        let available: [String]

        func withCompletion(confirmed: Bool, _ body: (UnsafePointer<ghostty_clipboard_complete_s>) -> Void) {
            var strings: [UnsafeMutablePointer<CChar>] = []
            var buffers: [UnsafeMutablePointer<CChar>] = []
            func copyString(_ string: String) -> UnsafePointer<CChar> {
                let bytes = Array(string.utf8CString)
                let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
                pointer.initialize(from: bytes, count: bytes.count)
                strings.append(pointer)
                return UnsafePointer(pointer)
            }
            defer {
                strings.forEach { $0.deallocate() }
                buffers.forEach { $0.deallocate() }
            }
            let cContents = contents.map { entry in
                // Even empty representations have a valid pointer for the C ABI.
                let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: max(entry.data.count, 1))
                buffers.append(pointer)
                entry.data.withUnsafeBytes { bytes in
                    if let base = bytes.baseAddress, !bytes.isEmpty {
                        UnsafeMutableRawPointer(pointer).copyMemory(from: base, byteCount: bytes.count)
                    }
                }
                return ghostty_clipboard_content_s(mime: copyString(entry.mime), data: pointer, len: entry.data.count)
            }
            let cAvailable: [UnsafePointer<CChar>?] = available.map { copyString($0) }
            cContents.withUnsafeBufferPointer { contentsBuffer in
                cAvailable.withUnsafeBufferPointer { availableBuffer in
                    var complete = ghostty_clipboard_complete_s(
                        contents: contentsBuffer.baseAddress,
                        contents_len: contentsBuffer.count,
                        available: availableBuffer.baseAddress,
                        available_len: availableBuffer.count,
                        confirmed: confirmed,
                        remember: false
                    )
                    withUnsafePointer(to: &complete, body)
                }
            }
        }
    }

    nonisolated(unsafe) private static let selectionPasteboard = NSPasteboard.withUniqueName()
    static var selectionPasteboardName: NSPasteboard.Name { selectionPasteboard.name }
    static let supportsSelectionClipboard = true

    static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return .general
        case GHOSTTY_CLIPBOARD_SELECTION:
            // Selection must not implicitly replace the macOS system clipboard.
            return selectionPasteboard
        default:
            return nil
        }
    }

    static func releaseSelectionPasteboardIfNeeded() {
        selectionPasteboard.releaseGlobally()
    }

    static func mimeStrings(from pointer: UnsafePointer<UnsafePointer<CChar>?>?, count: Int) -> [String] {
        guard let pointer, count > 0 else { return [] }
        return UnsafeBufferPointer(start: pointer, count: count).compactMap { $0.map { String(cString: $0) } }
    }

    static func entries(from pointer: UnsafePointer<ghostty_clipboard_content_s>?, count: Int) -> [Entry] {
        guard let pointer, count > 0 else { return [] }
        return UnsafeBufferPointer(start: pointer, count: count).compactMap { content in
            guard let mime = content.mime, content.len == 0 || content.data != nil else { return nil }
            let data = content.len == 0 ? Data() : Data(bytes: content.data!, count: content.len)
            return Entry(mime: String(cString: mime), data: data)
        }
    }

    static func read(from pasteboard: NSPasteboard, mimes: [String], list: Bool) -> ReadContents? {
        var seen = Set<String>()
        let contents: [Entry] = mimes.compactMap { mime in
            guard seen.insert(mime).inserted else { return nil }
            let data: Data?
            if mime == "text/plain" {
                data = stringContents(from: pasteboard).map { Data($0.utf8) }
            } else {
                data = pasteboard.data(forType: pasteboardType(for: mime))
            }
            return data.map { Entry(mime: mime, data: $0) }
        }
        guard !contents.isEmpty || list else { return nil }
        return ReadContents(contents: contents, available: list ? availableMimes(on: pasteboard) : [])
    }

    static func write(_ entries: [Entry], to pasteboard: NSPasteboard) {
        guard !entries.isEmpty else { return }
        let values = entries.map { (type: pasteboardType(for: $0.mime), data: $0.data) }
        pasteboard.declareTypes(values.map(\.type), owner: nil)
        for value in values {
            if value.type == .string {
                // Preserve the previous text callback's UTF-8 repair behavior.
                pasteboard.setString(String(decoding: value.data, as: UTF8.self), forType: .string)
            } else {
                pasteboard.setData(value.data, forType: value.type)
            }
        }
    }

    private static func pasteboardType(for mime: String) -> NSPasteboard.PasteboardType {
        if mime == "text/plain" { return .string }
        return NSPasteboard.PasteboardType(UTType(mimeType: mime)?.identifier ?? mime)
    }

    private static func stringContents(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.map { url in
                url.isFileURL ? "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" : url.absoluteString
            }.joined(separator: " ")
        }
        return pasteboard.string(forType: .string)
    }

    private static func availableMimes(on pasteboard: NSPasteboard) -> [String] {
        // Listing must not ask lazy pasteboard providers to materialize payloads.
        let types = pasteboard.types ?? []
        var result: [String] = []
        var seen = Set<String>()
        if types.contains(.string) || types.contains(.fileURL) || types.contains(.URL) {
            result.append("text/plain")
            seen.insert("text/plain")
        }
        for type in types {
            let mapped = UTType(type.rawValue)?.preferredMIMEType
            let mime = mapped == "text/plain;charset=utf-8" ? "text/plain" : mapped
            // Unknown representations written with a MIME identifier can also be listed.
            guard let mime = mime ?? (type.rawValue.contains("/") ? type.rawValue : nil),
                  seen.insert(mime).inserted else { continue }
            result.append(mime)
        }
        return result
    }
}
#endif
