// A drag source for remote-quick-entry-check.py: a small window in another
// process that starts a real AppKit drag when the mouse goes down on it, as
// Finder or a screenshot thumbnail does. The check then moves the mouse with
// quick-entry-ui-driver.swift's `drag` command.
//
// Usage: quick-entry-drag-source <file|promise|image> <path> <x> <y>
//   file     drags the file's URL, as Finder does
//   promise  drags a promise of a PNG, written from <path> when the
//            receiver asks, as screenshot thumbnails do
//   image    drags PNG data with no file
// <x> <y> is the window's top-left corner in global screen coordinates with
// the origin at the top left, as Accessibility and CGEvent use. The process
// prints "ready" once the window is up and exits when the drag ends.

import AppKit
import UniformTypeIdentifiers

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 4, let x = Double(arguments[2]), let y = Double(arguments[3]) else {
    FileHandle.standardError.write(Data("usage: quick-entry-drag-source <file|promise|image> <path> <x> <y>\n".utf8))
    exit(2)
}
let mode = arguments[0]
let sourceURL = URL(fileURLWithPath: arguments[1])
let windowSize = NSSize(width: 120, height: 80)

final class PromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "Promised screenshot.png"
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        completionHandler(Result { try FileManager.default.copyItem(at: sourceURL, to: url) }.error)
    }
}

extension Result where Failure == any Error {
    var error: (any Error)? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

final class SourceView: NSView, NSDraggingSource {
    let promiseWriter = PromiseWriter()

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.setFill()
        bounds.fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let writer: any NSPasteboardWriting
        switch mode {
        case "file":
            writer = sourceURL as NSURL
        case "promise":
            writer = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: promiseWriter)
        case "image":
            let item = NSPasteboardItem()
            item.setData((try? Data(contentsOf: sourceURL)) ?? Data(), forType: .png)
            writer = item
        default:
            FileHandle.standardError.write(Data("unknown mode \(mode)\n".utf8))
            exit(2)
        }
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(bounds, contents: NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        })
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        print("ended \(operation.rawValue)")
        fflush(stdout)
        // Give a promise time to be written before the process goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
let window = NSWindow(
    contentRect: NSRect(x: x, y: primaryHeight - y - windowSize.height, width: windowSize.width, height: windowSize.height),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
window.level = .floating
window.contentView = SourceView(frame: NSRect(origin: .zero, size: windowSize))
window.orderFrontRegardless()
print("ready")
fflush(stdout)
app.run()
