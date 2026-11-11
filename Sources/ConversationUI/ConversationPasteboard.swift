#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Plain-text copy on the platform pasteboard.
@MainActor
enum ConversationPasteboard {
    #if canImport(AppKit) && !canImport(UIKit)
    /// The pasteboard a copy writes to. Tests set a private one, so that a
    /// test run never changes the user's clipboard.
    static var pasteboard = NSPasteboard.general
    #endif

    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #endif
    }
}
