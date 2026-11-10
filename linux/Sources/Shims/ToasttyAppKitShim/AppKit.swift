import Foundation

// The AppKit subset the UI-free App layer touches, under AppKit's names.
// Everything with a user-visible effect forwards to `LinuxPlatform.services`.
// Views, windows, and responders are lightweight proxies: the GTK frontend
// owns the real widgets and reports them through `LinuxPlatformServices`.

public struct NSUserInterfaceItemIdentifier: RawRepresentable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public typealias NSSize = CGSize
public typealias NSRect = CGRect
public typealias NSPoint = CGPoint

public struct NSEdgeInsets: Equatable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat
    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

public struct NSEventModifierFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let capsLock = Self(rawValue: 1 << 16)
    public static let shift = Self(rawValue: 1 << 17)
    public static let control = Self(rawValue: 1 << 18)
    public static let option = Self(rawValue: 1 << 19)
    public static let command = Self(rawValue: 1 << 20)
    public static let numericPad = Self(rawValue: 1 << 21)
    public static let help = Self(rawValue: 1 << 22)
    public static let function = Self(rawValue: 1 << 23)
    public static let deviceIndependentFlagsMask = Self(rawValue: 0xFFFF_0000)
}

public enum NSEvent {
    public typealias ModifierFlags = NSEventModifierFlags
}

@MainActor
open class NSResponder {
    public init() {}
}

/// A text editor responder. On Linux it only exists so focus policy checks
/// (`firstResponder as? NSTextView`) can answer "a text field has focus".
@MainActor
open class NSTextView: NSResponder {
    open var isFieldEditor: Bool

    public init(isFieldEditor: Bool = true) {
        self.isFieldEditor = isFieldEditor
        super.init()
    }
}

/// Opaque host-container handle. GTK widgets never subclass this; it exists
/// for shared protocols such as `PanelHostLifecycleControlling` and for
/// automation screenshots of a window's content.
@MainActor
open class NSView: NSResponder {
    public let hostWindowID: UUID?
    open var bounds: CGRect
    open var frame: CGRect

    public init(frame: CGRect = .zero, hostWindowID: UUID? = nil) {
        self.frame = frame
        self.bounds = CGRect(origin: .zero, size: frame.size)
        self.hostWindowID = hostWindowID
        super.init()
    }

    open func bitmapImageRepForCachingDisplay(in rect: CGRect) -> NSBitmapImageRep? {
        _ = rect
        guard let hostWindowID else { return nil }
        return NSBitmapImageRep(windowID: hostWindowID)
    }

    open func cacheDisplay(in rect: CGRect, to bitmapImageRep: NSBitmapImageRep) {
        _ = rect
        bitmapImageRep.capture()
    }
}

/// Window proxy built from a `LinuxWindowSnapshot`.
@MainActor
open class NSWindow: NSResponder {
    public let windowID: UUID
    open var identifier: NSUserInterfaceItemIdentifier?
    open var frame: CGRect
    open var isVisible: Bool
    open var isMiniaturized: Bool
    open var isKeyWindow: Bool
    open var isMainWindow: Bool
    open var firstResponder: NSResponder?
    open var contentView: NSView?

    public init(snapshot: LinuxWindowSnapshot) {
        windowID = snapshot.id
        identifier = NSUserInterfaceItemIdentifier(snapshot.id.uuidString)
        frame = snapshot.frame
        isVisible = snapshot.isVisible
        isMiniaturized = snapshot.isMiniaturized
        isKeyWindow = snapshot.isKey
        isMainWindow = snapshot.isMain
        firstResponder = snapshot.hasTextInputFocus ? NSTextView(isFieldEditor: true) : nil
        contentView = NSView(frame: CGRect(origin: .zero, size: snapshot.frame.size), hostWindowID: snapshot.id)
        super.init()
    }

    open func makeKeyAndOrderFront(_ sender: Any?) {
        _ = sender
        LinuxPlatform.services.presentWindow(id: windowID, makeKey: true)
    }

    open func orderFront(_ sender: Any?) {
        _ = sender
        LinuxPlatform.services.presentWindow(id: windowID, makeKey: false)
    }

    open func displayIfNeeded() {}
}

@MainActor
public final class NSApplication {
    public static let shared = NSApplication()

    public struct ModalResponse: RawRepresentable, Hashable, Sendable {
        public var rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public init(_ rawValue: Int) { self.rawValue = rawValue }
        public static let OK = ModalResponse(rawValue: 1)
        public static let cancel = ModalResponse(rawValue: 0)
        public static let stop = ModalResponse(rawValue: -1000)
        public static let abort = ModalResponse(rawValue: -1001)
        public static let `continue` = ModalResponse(rawValue: -1002)
        public static let alertFirstButtonReturn = ModalResponse(rawValue: 1000)
        public static let alertSecondButtonReturn = ModalResponse(rawValue: 1001)
        public static let alertThirdButtonReturn = ModalResponse(rawValue: 1002)
    }

    public nonisolated static let didBecomeActiveNotification = Notification.Name("NSApplicationDidBecomeActiveNotification")
    public nonisolated static let didResignActiveNotification = Notification.Name("NSApplicationDidResignActiveNotification")
    public nonisolated static let willTerminateNotification = Notification.Name("NSApplicationWillTerminateNotification")
    public nonisolated static let didChangeScreenParametersNotification = Notification.Name("NSApplicationDidChangeScreenParametersNotification")
    public nonisolated static let didFinishLaunchingNotification = Notification.Name("NSApplicationDidFinishLaunchingNotification")

    private init() {}

    public var isActive: Bool { LinuxPlatform.services.isApplicationActive }

    public var windows: [NSWindow] {
        LinuxPlatform.services.windowSnapshots().map(NSWindow.init(snapshot:))
    }

    public var keyWindow: NSWindow? { windows.first(where: \.isKeyWindow) }

    public var mainWindow: NSWindow? { windows.first(where: \.isMainWindow) ?? keyWindow }

    public func activate(ignoringOtherApps flag: Bool) {
        _ = flag
        LinuxPlatform.services.activateApplication()
    }

    public func activate() {
        LinuxPlatform.services.activateApplication()
    }
}

@MainActor
public var NSApp: NSApplication { NSApplication.shared }

/// Screen proxy. Not main-actor bound (AppKit's NSScreen is not either):
/// off the main thread `screens` returns the last list the main thread saw.
public final class NSScreen: @unchecked Sendable {
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let backingScaleFactor: CGFloat
    public let localizedName: String

    init(snapshot: LinuxScreenSnapshot) {
        frame = snapshot.frame
        visibleFrame = snapshot.visibleFrame
        backingScaleFactor = snapshot.scale
        localizedName = snapshot.name
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedSnapshots: [LinuxScreenSnapshot] = []
    nonisolated(unsafe) private static var cachedScreens: [NSScreen] = []

    /// Identity is stable while the screen list is unchanged, so callers can
    /// compare `screen === NSScreen.main` like on macOS.
    public static var screens: [NSScreen] {
        let snapshots: [LinuxScreenSnapshot]? = LinuxMainQueue.isCurrent
            ? MainActor.assumeIsolated { LinuxPlatform.services.screenSnapshots() }
            : nil
        return lock.withLock {
            if let snapshots, snapshots != cachedSnapshots {
                cachedSnapshots = snapshots
                cachedScreens = snapshots.map(NSScreen.init(snapshot:))
            }
            return cachedScreens
        }
    }

    public static var main: NSScreen? { screens.first }
}

@MainActor
public final class NSWorkspace {
    public static let shared = NSWorkspace()
    private init() {}

    @discardableResult
    public func open(_ url: URL) -> Bool {
        LinuxPlatform.services.openURL(url)
    }

    public var accessibilityDisplayShouldReduceMotion: Bool { false }
}

public struct NSPasteboardType: RawRepresentable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let string = NSPasteboardType(rawValue: "public.utf8-plain-text")
    public static let fileURL = NSPasteboardType(rawValue: "public.file-url")
}

@MainActor
public final class NSPasteboard {
    public typealias PasteboardType = NSPasteboardType
    /// The desktop clipboard (LinuxPlatformServices).
    public static let general = NSPasteboard(isGeneral: true)
    private let isGeneral: Bool
    private var localString: String?

    private init(isGeneral: Bool) {
        self.isGeneral = isGeneral
    }

    /// A private, process-local pasteboard.
    public static func withUniqueName() -> NSPasteboard {
        NSPasteboard(isGeneral: false)
    }

    @discardableResult
    public func clearContents() -> Int {
        localString = nil
        return 0
    }

    @discardableResult
    public func setString(_ string: String, forType dataType: NSPasteboardType) -> Bool {
        _ = dataType
        guard isGeneral else {
            localString = string
            return true
        }
        return LinuxPlatform.services.writeClipboardString(string)
    }

    public func string(forType dataType: NSPasteboardType) -> String? {
        _ = dataType
        return isGeneral ? LinuxPlatform.services.readClipboardString() : localString
    }

    public func releaseGlobally() {}
}

@MainActor
public final class NSButton {
    public var title: String
    public var keyEquivalent: String = ""
    public var keyEquivalentModifierMask: NSEventModifierFlags = []
    public var state: NSControlStateValue = .off
    /// Destructive styling hint (red button in AdwAlertDialog).
    public var hasDestructiveAction = false

    public init(title: String) {
        self.title = title
    }
}

public struct NSControlStateValue: RawRepresentable, Hashable, Sendable {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let off = NSControlStateValue(rawValue: 0)
    public static let on = NSControlStateValue(rawValue: 1)
    public static let mixed = NSControlStateValue(rawValue: -1)
}

/// `NSAlert` that presents through `LinuxPlatformServices`.
@MainActor
public final class NSAlert {
    public enum Style: Sendable {
        case warning
        case informational
        case critical
    }

    public var messageText = ""
    public var informativeText = ""
    public var alertStyle: Style = .warning
    public private(set) var buttons: [NSButton] = []
    public var showsSuppressionButton = false
    public private(set) lazy var suppressionButton: NSButton? = NSButton(title: "Do not show this message again")

    public init() {}

    @discardableResult
    public func addButton(withTitle title: String) -> NSButton {
        let button = NSButton(title: title)
        // AppKit's defaults: Return on the first button, Escape on "Cancel".
        if buttons.isEmpty {
            button.keyEquivalent = "\r"
        } else if title == "Cancel" {
            button.keyEquivalent = "\u{1B}"
        }
        buttons.append(button)
        return button
    }

    public var request: LinuxAlertRequest {
        LinuxAlertRequest(
            style: {
                switch alertStyle {
                case .warning: .warning
                case .informational: .informational
                case .critical: .critical
                }
            }(),
            messageText: messageText,
            informativeText: informativeText,
            buttons: (buttons.isEmpty ? [NSButton(title: "OK")] : buttons).map {
                LinuxAlertRequest.Button(title: $0.title, keyEquivalent: $0.keyEquivalent)
            },
            showsSuppressionButton: showsSuppressionButton,
            suppressionButtonTitle: showsSuppressionButton ? suppressionButton?.title : nil
        )
    }

    @discardableResult
    public func runModal() -> NSApplication.ModalResponse {
        response(forButtonIndex: LinuxPlatform.services.runModalAlert(request))
    }

    public func beginSheetModal(
        for window: NSWindow,
        completionHandler handler: (@MainActor (NSApplication.ModalResponse) -> Void)? = nil
    ) {
        LinuxPlatform.services.presentAlert(request, windowID: window.windowID) { [weak self] index in
            guard let self else { return }
            handler?(self.response(forButtonIndex: index))
        }
    }

    private func response(forButtonIndex index: Int) -> NSApplication.ModalResponse {
        // A suppression checkbox result is encoded by the frontend as
        // index | suppressionFlag so a single Int carries both answers.
        let suppressed = index & LinuxAlertResponse.suppressionFlag != 0
        if showsSuppressionButton {
            suppressionButton?.state = suppressed ? .on : .off
        }
        let buttonIndex = index & ~LinuxAlertResponse.suppressionFlag
        return NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + buttonIndex)
    }
}

public enum LinuxAlertResponse {
    /// OR this into a button index when the alert's suppression checkbox
    /// ("Always quit without asking") was checked.
    public static let suppressionFlag = 1 << 16
}

/// RGBA8 bitmap with PNG encoding; the Linux backing for `NSImage`.
public struct LinuxBitmap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Row-major RGBA, 4 bytes per pixel.
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4, "bitmap size mismatch")
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let offset = (y * width + x) * 4
        return (rgba[offset], rgba[offset + 1], rgba[offset + 2], rgba[offset + 3])
    }

    public func pngData() -> Data {
        PNGEncoder.encode(self)
    }
}

public final class NSImage: @unchecked Sendable {
    public let size: CGSize
    public let bitmap: LinuxBitmap?
    private let encodedPNG: Data?

    public init(bitmap: LinuxBitmap, size: CGSize? = nil) {
        self.bitmap = bitmap
        self.size = size ?? CGSize(width: bitmap.width, height: bitmap.height)
        encodedPNG = nil
    }

    /// Wraps already-encoded PNG bytes (e.g. a favicon). The bitmap is not
    /// decoded on Linux; the frontend loads `pngData` with GdkTexture.
    public init?(pngData: Data, size: CGSize) {
        guard pngData.starts(with: PNGEncoder.signature) else { return nil }
        bitmap = nil
        self.size = size
        encodedPNG = pngData
    }

    public var pngData: Data? {
        encodedPNG ?? bitmap?.pngData()
    }

    /// AppKit's TIFF export, which shared code feeds to
    /// `NSBitmapImageRep(data:)` to re-encode as PNG. Linux images are PNG
    /// already, so this is the PNG encoding.
    public var tiffRepresentation: Data? { pngData }
}

/// Window captures (`NSView.cacheDisplay`) and already-encoded images
/// (`init(data:)`, PNG only on Linux).
public final class NSBitmapImageRep: @unchecked Sendable {
    public enum FileType: Sendable {
        case png
    }

    public struct PropertyKey: Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }

    private let windowID: UUID?
    private var png: Data?

    init(windowID: UUID) {
        self.windowID = windowID
    }

    /// Wraps encoded image bytes; Linux only decodes PNG here.
    public init?(data: Data) {
        guard data.starts(with: PNGEncoder.signature) else { return nil }
        windowID = nil
        png = data
    }

    @MainActor
    func capture() {
        guard let windowID else { return }
        png = LinuxPlatform.services.captureWindowPNG(id: windowID)
    }

    public func representation(using storageType: FileType, properties: [PropertyKey: Any]) -> Data? {
        _ = storageType
        _ = properties
        return png
    }
}

extension NSWorkspace {
    /// Reveals files in the file manager: opens the parent folder of the
    /// first item (portals/Nautilus have no portable "select" call).
    public func activateFileViewerSelecting(_ fileURLs: [URL]) {
        guard let first = fileURLs.first else { return }
        _ = LinuxPlatform.services.openURL(first.deletingLastPathComponent())
    }
}

/// sRGB color value with HSB accessors (no drawing on Linux).
public final class NSColor: @unchecked Sendable, Equatable {
    public struct ColorSpaceName: Hashable, Sendable {
        public let rawValue: String
        public static let deviceRGB = ColorSpaceName(rawValue: "NSDeviceRGBColorSpace")
        public static let sRGB = ColorSpaceName(rawValue: "NSCalibratedRGBColorSpace")
    }

    public let redComponent: CGFloat
    public let greenComponent: CGFloat
    public let blueComponent: CGFloat
    public let alphaComponent: CGFloat

    public init(calibratedRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        redComponent = red
        greenComponent = green
        blueComponent = blue
        alphaComponent = alpha
    }

    public convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }

    public static let white = NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1)
    public static let black = NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 1)

    public func withAlphaComponent(_ alpha: CGFloat) -> NSColor {
        NSColor(calibratedRed: redComponent, green: greenComponent, blue: blueComponent, alpha: alpha)
    }

    public func usingColorSpace(_ space: ColorSpaceName) -> NSColor? {
        _ = space
        return self
    }

    public var brightnessComponent: CGFloat { max(redComponent, greenComponent, blueComponent) }

    public var saturationComponent: CGFloat {
        let maximum = brightnessComponent
        guard maximum > 0 else { return 0 }
        return (maximum - min(redComponent, greenComponent, blueComponent)) / maximum
    }

    /// Hue in 0..<1, as AppKit reports it.
    public var hueComponent: CGFloat {
        let r = redComponent, g = greenComponent, b = blueComponent
        let maximum = max(r, g, b)
        let delta = maximum - min(r, g, b)
        guard delta > 0 else { return 0 }
        var hue: CGFloat
        if maximum == r {
            hue = (g - b) / delta
        } else if maximum == g {
            hue = 2 + (b - r) / delta
        } else {
            hue = 4 + (r - g) / delta
        }
        hue /= 6
        return hue < 0 ? hue + 1 : hue
    }

    public static func == (lhs: NSColor, rhs: NSColor) -> Bool {
        lhs.redComponent == rhs.redComponent && lhs.greenComponent == rhs.greenComponent
            && lhs.blueComponent == rhs.blueComponent && lhs.alphaComponent == rhs.alphaComponent
    }
}

/// Font description only (size and weight); GTK draws text with Pango.
public final class NSFont: @unchecked Sendable, Equatable {
    public struct Weight: Hashable, Sendable {
        public let rawValue: CGFloat
        public init(rawValue: CGFloat) { self.rawValue = rawValue }
        public static let regular = Weight(rawValue: 0)
        public static let medium = Weight(rawValue: 0.23)
        public static let semibold = Weight(rawValue: 0.3)
        public static let bold = Weight(rawValue: 0.4)
    }

    public let pointSize: CGFloat
    public let weight: Weight

    init(pointSize: CGFloat, weight: Weight) {
        self.pointSize = pointSize
        self.weight = weight
    }

    public static func systemFont(ofSize size: CGFloat, weight: Weight = .regular) -> NSFont {
        NSFont(pointSize: size, weight: weight)
    }

    public static func == (lhs: NSFont, rhs: NSFont) -> Bool {
        lhs.pointSize == rhs.pointSize && lhs.weight == rhs.weight
    }
}
