// A small window to drag a file from, for a live check of a drop target.
//
// Usage:
//   drag-source file <path> <ready-file>     Drag the file, as Finder does.
//   drag-source promise <path> <ready-file>  Drag a promise of the file, as
//                                            a screenshot's thumbnail does.
//   drag-source copy-png <path>              Put the PNG on the general
//                                            pasteboard as image data, and exit.
//
// With `file` or `promise`, it shows an orange square at the top left of the
// main screen and writes the square's middle to `ready-file` as "x y", in
// screen coordinates with the origin at the top left. A drag from there,
// such as `ax-drive drag`, carries the file. Each finished drag appends a
// line to `<ready-file>.log`. It runs until it is killed.
import AppKit
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: drag-source <file|promise|copy-png> <path> [ready-file]\n".utf8))
    exit(64)
}
let mode = arguments[1]
let fileURL = URL(fileURLWithPath: arguments[2])

if mode == "copy-png" {
    guard let data = try? Data(contentsOf: fileURL) else { exit(66) }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setData(data, forType: .png)
    print("copied \(data.count) bytes of PNG")
    exit(0)
}
guard arguments.count >= 4, mode == "file" || mode == "promise" else { exit(64) }
let readyURL = URL(fileURLWithPath: arguments[3])
let logURL = URL(fileURLWithPath: arguments[3] + ".log")

func log(_ line: String) {
    let previous = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    try? (previous + line + "\n").write(to: logURL, atomically: true, encoding: .utf8)
}

final class SourceView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    private var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.setFill()
        bounds.fill()
        (fileURL.lastPathComponent as NSString).draw(
            at: NSPoint(x: 8, y: bounds.midY - 7),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.black]
        )
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard isDragging == false else { return }
        isDragging = true
        let writer: NSPasteboardWriting = mode == "promise"
            ? NSFilePromiseProvider(fileType: UTType(filenameExtension: fileURL.pathExtension)?.identifier ?? UTType.data.identifier, delegate: self)
            : fileURL as NSURL
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(bounds, contents: NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.systemOrange.withAlphaComponent(0.7).setFill()
            rect.fill()
            return true
        })
        beginDraggingSession(with: [item], event: event, source: self)
        log("began \(mode)")
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        log("ended operation=\(operation.rawValue)")
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileURL.lastPathComponent
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try FileManager.default.copyItem(at: fileURL, to: url)
            log("wrote promise to \(url.path)")
            completionHandler(nil)
        } catch {
            log("promise failed: \(error)")
            completionHandler(error)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0]
let size = NSSize(width: 150, height: 70)
let origin = NSPoint(x: screen.frame.minX + 30, y: screen.frame.maxY - 140 - size.height)
let window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
window.level = .floating
window.contentView = SourceView(frame: NSRect(origin: .zero, size: size))
window.orderFrontRegardless()
// The middle, with the origin at the top left of the main screen.
let middle = NSPoint(x: window.frame.midX, y: screen.frame.maxY - window.frame.midY)
try "\(Int(middle.x)) \(Int(middle.y))".write(to: readyURL, atomically: true, encoding: .utf8)
app.run()
