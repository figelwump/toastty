#if canImport(AppKit) && !canImport(UIKit)
import AppKit
import SwiftUI

/// One paragraph of a run of Markdown text that shares a single text view.
/// A drag selects across every paragraph in the view.
struct ToasttySelectableParagraph: Equatable {
    enum Decoration: Equatable {
        case none
        /// A list item: its marker sits in a column before the text, and
        /// wrapped lines align with the text.
        case listMarker(String, depth: Int)
        /// A block quote: a bar before the text.
        case quote
    }

    var text: AttributedString
    var textStyle: NSFont.TextStyle = .body
    var weight: NSFont.Weight?
    var textColor: Color = ConversationDesignTokens.primaryText
    /// The gap above the paragraph, as between blocks in their own views.
    /// The first paragraph's is ignored.
    var spacingBefore: CGFloat = 0
    var decoration: Decoration = .none
}

/// The AppKit counterpart of the UIKit text view: `NSTextView` supplies range
/// selection for the same attributed runs, and the transcript owns scrolling.
@MainActor
struct ToasttySelectableText: NSViewRepresentable {
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.conversationTextScale) private var textScale
    @Environment(\.openURL) private var openURL

    let paragraphs: [ToasttySelectableParagraph]
    var monospaced = false
    var lineSpacing: CGFloat = 6
    var alignment: NSTextAlignment = .natural
    /// Several Markdown blocks in one view: a line break inside a block
    /// must not start a new paragraph, which would take the block's spacing
    /// and the first-line position of its list marker.
    private var keepsLineBreaksInsideParagraphs = false

    init(_ text: AttributedString, textStyle: NSFont.TextStyle = .body,
         weight: NSFont.Weight? = nil, monospaced: Bool = false,
         textColor: Color = ConversationDesignTokens.primaryText,
         lineSpacing: CGFloat = 6, alignment: NSTextAlignment = .natural) {
        self.paragraphs = [ToasttySelectableParagraph(
            text: text, textStyle: textStyle, weight: weight, textColor: textColor
        )]
        self.monospaced = monospaced
        self.lineSpacing = lineSpacing
        self.alignment = alignment
    }

    init(paragraphs: [ToasttySelectableParagraph]) {
        self.paragraphs = paragraphs
        self.keepsLineBreaksInsideParagraphs = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ToasttyTranscriptTextView {
        // TextKit 1, so the separate sizing stack below measures the same
        // layout that the view draws.
        let view = ToasttyTranscriptTextView(usingTextLayoutManager: false)
        // Draws a quote's bar and a chip's spinner. The view draws the
        // outline of a chip behind its text.
        view.textContainer?.replaceLayoutManager(ToasttyChipLayoutManager())
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        // Each run already has its link color. AppKit's default overrides it.
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ToasttyTranscriptTextView, context: Context) {
        context.coordinator.openURL = openURL
        let rendered = attributedText()
        let previous = context.coordinator.renderedText
        guard !rendered.isEqual(to: previous) else { return }
        context.coordinator.renderedText = rendered
        context.coordinator.sizingTextStorage.setAttributedString(rendered)
        context.coordinator.measuredSizes.removeAll(keepingCapacity: true)
        context.coordinator.idealWidth = nil
        // Append only if the existing rendered prefix is unchanged, as on iOS.
        if previous.length > 0, rendered.length > previous.length,
           rendered.attributedSubstring(from: NSRange(location: 0, length: previous.length)).isEqual(to: previous) {
            let selection = view.selectedRanges
            view.textStorage?.append(rendered.attributedSubstring(from: NSRange(
                location: previous.length, length: rendered.length - previous.length
            )))
            view.selectedRanges = selection
        } else {
            // One view holds several paragraphs. A change later in the text,
            // such as a chip's color or a link that finished streaming, keeps
            // a selection in the unchanged text before it.
            let unchanged = Self.commonPrefixLength(previous.string, rendered.string)
            let kept = view.selectedRanges.filter {
                let range = $0.rangeValue
                return range.length > 0 && NSMaxRange(range) <= unchanged
            }
            view.textStorage?.setAttributedString(rendered)
            if kept.isEmpty {
                view.setSelectedRange(NSRange(location: 0, length: 0))
            } else {
                view.selectedRanges = kept
            }
        }
        view.chipRoomAbove = context.coordinator.sizingLayoutManager.chipRoom(in: rendered)?.above ?? 0
        view.invalidateIntrinsicContentSize()
        view.updateChipSpinners()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ToasttyTranscriptTextView,
                      context: Context) -> CGSize? {
        if let width = proposal.width, width <= 0 { return .zero }
        let ideal: CGFloat
        if let cached = context.coordinator.idealWidth {
            ideal = cached
        } else {
            // Alignment moves line origins, not the content's ideal width. A
            // natural-alignment copy keeps centered and trailing text from
            // reporting the whole probe width.
            let sizingText = NSMutableAttributedString(attributedString: context.coordinator.renderedText)
            sizingText.enumerateAttribute(
                .paragraphStyle, in: NSRange(location: 0, length: sizingText.length)
            ) { value, range, _ in
                guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                else { return }
                style.alignment = .natural
                sizingText.addAttribute(.paragraphStyle, value: style, range: range)
            }
            // Leave one point for TextKit's fractional glyph layout, so short
            // bubbles do not wrap their last character at the measured edge.
            ideal = ceil(sizingText.boundingRect(
                with: CGSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).width) + 1
            context.coordinator.idealWidth = ideal
        }
        let width = max(1, min(proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal, max(1, ideal)))
        if let cached = context.coordinator.measuredSizes[width] { return cached }
        // The live container follows the placed text view. Measure proposals
        // in a separate TextKit stack, so an earlier frame cannot supply the
        // height for a new width.
        let container = context.coordinator.sizingTextContainer
        let layout = context.coordinator.sizingLayoutManager
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        // Room for a chip's outline above the first line and below the
        // last, where TextKit adds no line spacing.
        let room = layout.chipRoom(in: context.coordinator.renderedText)
        let size = CGSize(width: width, height: ceil(layout.usedRect(for: container).height
                                                     + (room?.above ?? 0) + (room?.below ?? 0)))
        context.coordinator.measuredSizes[width] = size
        return size
    }

    static func dismantleNSView(_ view: ToasttyTranscriptTextView, coordinator: Coordinator) {
        view.delegate = nil
        view.stopChipSpinners()
    }

    private func attributedText() -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        var previous: (paragraph: ToasttySelectableParagraph, attributes: [NSAttributedString.Key: Any])?
        for paragraph in paragraphs {
            let style = paragraphStyle(for: paragraph, isFirst: previous == nil)
            if let previous {
                // The break belongs to the paragraph before it. A copy keeps a
                // blank line between blocks, except between list items.
                var attributes = previous.attributes
                attributes[.toasttyCopyText] = Self.isListItem(previous.paragraph)
                    && Self.isListItem(paragraph) ? "\n" : "\n\n"
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            if case .listMarker(let label, let depth) = paragraph.decoration {
                let markerAttributes: [NSAttributedString.Key: Any] = [
                    .font: markerFont,
                    .foregroundColor: NSColor(ConversationDesignTokens.secondaryText),
                    .paragraphStyle: style,
                ]
                // Tab stops place the marker; a copy gets plain indentation.
                var leading = markerAttributes
                leading[.toasttyCopyText] = String(repeating: "  ", count: max(0, depth - 1))
                result.append(NSAttributedString(string: "\t", attributes: leading))
                result.append(NSAttributedString(string: label, attributes: markerAttributes))
                var separator = markerAttributes
                separator[.toasttyCopyText] = label.isEmpty ? "" : " "
                result.append(NSAttributedString(string: "\t", attributes: separator))
            }
            let start = result.length
            let attributes = appendRuns(of: paragraph, style: style, to: result)
            if case .quote = paragraph.decoration, result.length > start {
                result.addAttribute(.toasttyQuote, value: true,
                                    range: NSRange(location: start, length: result.length - start))
            }
            previous = (paragraph, attributes)
        }
        return result
    }

    /// Appends the paragraph's runs and returns the attributes of its last run.
    private func appendRuns(of paragraph: ToasttySelectableParagraph, style: NSParagraphStyle,
                            to result: NSMutableAttributedString) -> [NSAttributedString.Key: Any] {
        let boldText = legibilityWeight == .bold
        let preferred = scaled(NSFont.preferredFont(forTextStyle: paragraph.textStyle))
        let text = paragraph.text
        var last: [NSAttributedString.Key: Any] = [.font: preferred, .paragraphStyle: style]
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            let code = monospaced || intent.contains(.code)
            var runWeight = intent.contains(.stronglyEmphasized) ? NSFont.Weight.bold : paragraph.weight
            if boldText, let explicitWeight = runWeight {
                runWeight = explicitWeight.rawValue >= NSFont.Weight.bold.rawValue ? .heavy : .bold
            }
            var font = code
                ? NSFont.monospacedSystemFont(ofSize: preferred.pointSize, weight: runWeight ?? (boldText ? .semibold : .regular))
                : runWeight.map { NSFont.systemFont(ofSize: preferred.pointSize, weight: $0) } ?? preferred
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(run.foregroundColor ?? (run.link == nil ? paragraph.textColor : ConversationDesignTokens.amberText)),
                .paragraphStyle: style,
            ]
            if let color = run.backgroundColor { attributes[.backgroundColor] = NSColor(color) }
            if let link = run.link { attributes[.link] = link }
            // The chip's link names it, so two chips side by side keep two
            // outlines.
            if run[ConversationChipAttribute.self] != nil { attributes[.toasttyChip] = run.link ?? true }
            if run[ConversationChipSpinnerAttribute.self] == true {
                // The dot keeps its place in the line, drawn clear. The
                // layout manager draws a spinner in its color there.
                attributes[.toasttyChipSpinner] = attributes[.foregroundColor]
                attributes[.foregroundColor] = NSColor.clear
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            var characters = String(text[run.range].characters)
            if keepsLineBreaksInsideParagraphs {
                characters = characters.replacingOccurrences(of: "\n", with: Self.lineSeparator)
            }
            result.append(NSAttributedString(string: characters, attributes: attributes))
            last = attributes
        }
        last[.link] = nil
        last[.toasttyChip] = nil
        last[.toasttyChipSpinner] = nil
        last[.backgroundColor] = nil
        return last
    }

    private func paragraphStyle(for paragraph: ToasttySelectableParagraph,
                                isFirst: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.alignment = alignment
        // TextKit adds the line spacing below a paragraph's last line, except
        // at the end of the text, where a block in its own view ends.
        style.paragraphSpacingBefore = isFirst ? 0 : max(0, paragraph.spacingBefore - lineSpacing)
        switch paragraph.decoration {
        case .none:
            break
        case .listMarker(let label, let depth):
            // The SwiftUI list row: a marker column at least 16 points wide
            // with the marker at its trailing edge, 8 points, then the text.
            let indent = CGFloat(max(0, depth - 1)) * 16
            let labelWidth = ceil((label as NSString).size(withAttributes: [.font: markerFont]).width)
            let markerEdge = indent + max(16, labelWidth)
            let textStart = markerEdge + 8
            style.firstLineHeadIndent = indent
            style.headIndent = textStart
            style.tabStops = [
                NSTextTab(textAlignment: .right, location: markerEdge),
                NSTextTab(textAlignment: .left, location: textStart),
            ]
        case .quote:
            style.firstLineHeadIndent = Self.quoteTextIndent
            style.headIndent = Self.quoteTextIndent
        }
        return style
    }

    /// The length, in UTF-16 units, of the text that two strings share at
    /// their start.
    private static func commonPrefixLength(_ first: String, _ second: String) -> Int {
        let first = first as NSString, second = second as NSString
        let limit = min(first.length, second.length)
        var length = 0
        while length < limit, first.character(at: length) == second.character(at: length) {
            length += 1
        }
        return length
    }

    private static func isListItem(_ paragraph: ToasttySelectableParagraph) -> Bool {
        if case .listMarker = paragraph.decoration { return true }
        return false
    }

    private var markerFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: scaled(NSFont.preferredFont(forTextStyle: .body)).pointSize, weight: .regular)
    }

    /// The text style's font at the chat's text scale.
    private func scaled(_ font: NSFont) -> NSFont {
        textScale == 1 ? font : NSFont(descriptor: font.fontDescriptor, size: font.pointSize * textScale) ?? font
    }

    /// A 3-point bar, then 10 points of space.
    static let quoteBarWidth: CGFloat = 3
    static let quoteTextIndent: CGFloat = 13
    /// Breaks a line without starting a paragraph.
    static let lineSeparator = "\u{2028}"

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var renderedText = NSAttributedString(string: "")
        var idealWidth: CGFloat?
        var measuredSizes: [CGFloat: CGSize] = [:]
        var openURL: OpenURLAction?
        let sizingTextStorage = NSTextStorage(string: "")
        // The same line breaks as the drawn text view.
        let sizingLayoutManager = ToasttyChipLayoutManager()
        let sizingTextContainer = NSTextContainer(
            size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
        )

        override init() {
            super.init()
            sizingTextContainer.lineFragmentPadding = 0
            sizingTextContainer.widthTracksTextView = false
            sizingTextContainer.heightTracksTextView = false
            sizingLayoutManager.addTextContainer(sizingTextContainer)
            sizingTextStorage.addLayoutManager(sizingLayoutManager)
        }

        /// Every link goes to the host's `openURL`, which decides between a
        /// file preview and the system browser.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            openURL?(url)
            return true
        }
    }
}

/// Public so a host can tell that a reader is selecting transcript text.
@MainActor
public final class ToasttyTranscriptTextView: NSTextView {
    /// Turns the chip spinners while the view is in a window.
    private var chipSpinnerTimer: Timer?

    /// Room above the first line for a chip's outline. `sizeThatFits`
    /// adds the same room.
    var chipRoomAbove: CGFloat = 0 {
        didSet {
            guard chipRoomAbove != oldValue else { return }
            invalidateTextContainerOrigin()
            needsDisplay = true
        }
    }

    override public var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: origin.x, y: origin.y + chipRoomAbove)
    }

    /// The layout manager's drawing is clipped to the text container, and a
    /// chip's outline reaches above and below its line, so the view draws
    /// the outlines.
    override public func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let manager = layoutManager as? ToasttyChipLayoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        // Also the lines next to the rect: an outline reaches a few points
        // past its line.
        let lines = rect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 0, dy: -8)
        let glyphs = manager.glyphRange(forBoundingRect: lines, in: textContainer)
        manager.drawChipOutlines(forGlyphRange: glyphs, at: origin)
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = CGSize(width: newSize.width,
                                             height: CGFloat.greatestFiniteMagnitude)
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NSWorkspace.shared.notificationCenter
        let name = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        center.removeObserver(self, name: name, object: nil)
        if window != nil {
            // The spinners turn again when Reduce Motion goes off.
            center.addObserver(self, selector: #selector(displayOptionsDidChange), name: name, object: nil)
        }
        updateChipSpinners()
    }

    @objc private func displayOptionsDidChange(_ notification: Notification) {
        updateChipSpinners()
    }

    /// Starts the spinner timer when the view shows a chip spinner, and
    /// stops it when it does not. With Reduce Motion on, a spinner is a
    /// still arc.
    func updateChipSpinners() {
        let animates = window != nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !chipSpinnerRects().isEmpty
        guard animates else {
            stopChipSpinners()
            return
        }
        guard chipSpinnerTimer == nil else { return }
        // The rate of the app's other spinners.
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] timer in
            // A view that went away without leaving its window stops here.
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.turnChipSpinners() }
        }
        // `.common`, so the spinners also turn while the transcript scrolls.
        RunLoop.main.add(timer, forMode: .common)
        chipSpinnerTimer = timer
    }

    func stopChipSpinners() {
        chipSpinnerTimer?.invalidate()
        chipSpinnerTimer = nil
    }

    private func turnChipSpinners() {
        guard let manager = layoutManager as? ToasttyChipLayoutManager else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            manager.chipSpinnerAngle = 0
            stopChipSpinners()
        } else {
            manager.chipSpinnerAngle = ToasttyChipLayoutManager.chipSpinnerAngle(at: Date())
        }
        let visible = visibleRect
        for rect in chipSpinnerRects() where rect.intersects(visible) {
            setNeedsDisplay(rect.insetBy(dx: -1, dy: -1))
        }
    }

    /// Where each chip spinner is drawn, in the view's coordinates.
    func chipSpinnerRects() -> [NSRect] {
        guard let manager = layoutManager as? ToasttyChipLayoutManager, let textStorage,
              textStorage.length > 0 else { return [] }
        let origin = textContainerOrigin
        var rects: [NSRect] = []
        textStorage.enumerateAttribute(
            .toasttyChipSpinner, in: NSRange(location: 0, length: textStorage.length)
        ) { value, range, _ in
            guard value != nil else { return }
            rects += manager.chipSpinnerRects(forCharacterRange: range)
                .map { $0.offsetBy(dx: origin.x, dy: origin.y) }
        }
        return rects
    }

    override public func copy(_ sender: Any?) {
        _ = writeSelection(to: .general, types: [.string])
    }

    /// Copy and dragging the selection into another app both write plain
    /// text. Transcript colors belong to Toastty. Pasting elsewhere must not
    /// carry its dark-theme rich text or inline-code backgrounds.
    override public func writeSelection(to pboard: NSPasteboard,
                                        types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let copied = copiedText() else { return false }
        pboard.clearContents()
        return pboard.setString(copied, forType: .string)
    }

    /// The selection as plain text. List markers and the breaks between
    /// blocks have their own copy text. A chip keeps its words together with
    /// no-break spaces, and a line break inside a block is a line separator;
    /// a copy gets ordinary spaces and line breaks.
    func copiedText() -> String? {
        let range = selectedRange()
        guard range.length > 0, let textStorage else { return nil }
        var copied = ""
        let text = string as NSString
        textStorage.enumerateAttribute(.toasttyCopyText, in: range) { value, subrange, _ in
            copied += (value as? String) ?? text.substring(with: subrange)
        }
        return copied
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: ToasttySelectableText.lineSeparator, with: "\n")
    }
}

extension NSAttributedString.Key {
    /// Marks the characters of a chip. The value is the chip's link, so
    /// each chip has its own range. See `ConversationChipAttribute`.
    static let toasttyChip = NSAttributedString.Key("toastty.conversationChip")
    /// A chip's dot drawn as a spinner. The value is the spinner's color.
    /// See `ConversationChipSpinnerAttribute`.
    static let toasttyChipSpinner = NSAttributedString.Key("toastty.conversationChipSpinner")
    /// The characters of a block quote, which draw a bar before them.
    static let toasttyQuote = NSAttributedString.Key("toastty.conversationQuote")
    /// Replaces the characters in a copy, such as a list marker's tab stops.
    static let toasttyCopyText = NSAttributedString.Key("toastty.conversationCopyText")
}

/// Draws a rounded outline behind each run of chip text, and keeps a chip on
/// one line where the line allows it. Also draws a chip's spinner and the
/// bar before a block quote. The text itself, its colors and its link are
/// ordinary attributes.
final class ToasttyChipLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// The turn of every chip spinner, in radians. The text view advances it.
    var chipSpinnerAngle: CGFloat = 0

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        drawQuoteBars(in: characters, textStorage: textStorage, at: origin)
    }

    /// Draws the outline of each chip in the range behind its text.
    func drawChipOutlines(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard glyphsToShow.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        // The whole chip, also when only a part of it is drawn now.
        for chipRange in chipRanges(in: characters) {
            for rect in chipOutlineRects(forCharacterRange: chipRange) {
                let outline = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0.5, dy: 0.5)
                let path = NSBezierPath(roundedRect: outline, xRadius: outline.height / 2, yRadius: outline.height / 2)
                NSColor.white.withAlphaComponent(0.08).setFill()
                path.fill()
                NSColor.white.withAlphaComponent(0.22).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    /// The whole range of each chip with text in `characters`, also when
    /// only a part of the chip is in `characters`. Each range gets its own
    /// outline. Two chips side by side have different links, so they stay
    /// two ranges.
    func chipRanges(in characters: NSRange) -> [NSRange] {
        guard let textStorage else { return [] }
        let whole = NSRange(location: 0, length: textStorage.length)
        var ranges: [NSRange] = []
        textStorage.enumerateAttribute(.toasttyChip, in: characters) { value, range, _ in
            guard value != nil else { return }
            var chipRange = NSRange()
            _ = textStorage.attribute(.toasttyChip, at: range.location,
                                      longestEffectiveRange: &chipRange, in: whole)
            ranges.append(chipRange)
        }
        return ranges
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(.toasttyChipSpinner, in: characters) { value, range, _ in
            guard let color = value as? NSColor else { return }
            for rect in chipSpinnerRects(forCharacterRange: range) {
                drawChipSpinner(in: rect.offsetBy(dx: origin.x, dy: origin.y), color: color)
            }
        }
    }

    /// The spinner of `ToasttySpinner`: an arc that turns once every 0.9
    /// seconds.
    static func chipSpinnerAngle(at date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
        return CGFloat(phase) * 2 * .pi
    }

    private func drawChipSpinner(in rect: NSRect, color: NSColor) {
        let lineWidth = max(1, rect.width * 0.16)
        let radius = (rect.width - lineWidth) / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        // The arc of `ToasttySpinner`: from 16% to 90% of a turn, clockwise
        // on screen from the right. The text view is flipped.
        let start = chipSpinnerAngle + 0.16 * 2 * .pi
        let end = chipSpinnerAngle + 0.9 * 2 * .pi
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius,
                       startAngle: start * 180 / .pi, endAngle: end * 180 / .pi, clockwise: false)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// A square over the ink of each dot in the range, in the text
    /// container's coordinates. The spinner has the dot's size.
    func chipSpinnerRects(forCharacterRange range: NSRange) -> [NSRect] {
        guard let textStorage else { return [] }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [NSRect] = []
        for glyphIndex in glyphs.location..<NSMaxRange(glyphs) where isValidGlyphIndex(glyphIndex) {
            let characterIndex = characterIndexForGlyph(at: glyphIndex)
            guard characterIndex < textStorage.length,
                  let font = textStorage.attribute(.font, at: characterIndex, effectiveRange: nil) as? NSFont
            else { continue }
            let line = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let baseline = location(forGlyphAt: glyphIndex)
            // The glyph's ink, with y up from the baseline.
            let ink = font.boundingRect(forCGGlyph: cgGlyph(at: glyphIndex))
            guard ink.width > 0, ink.height > 0 else { continue }
            let side = min(ink.width, ink.height)
            let center = NSPoint(x: line.minX + baseline.x + ink.midX,
                                 y: Self.chipTextMiddle(baseline: line.minY + baseline.y, font: font))
            rects.append(NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
        }
        return rects
    }

    /// How far the outline of a chip reaches above its line's text and
    /// below it, in whole points. `nil` when the text has no chip.
    func chipRoom(in text: NSAttributedString) -> (above: CGFloat, below: CGFloat)? {
        var font: NSFont?
        text.enumerateAttribute(.toasttyChip, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            guard value != nil else { return }
            font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            stop.pointee = true
        }
        guard let font else { return nil }
        let lineHeight = defaultLineHeight(for: font)
        let middle = defaultBaselineOffset(for: font) - font.capHeight / 2
        let half = Self.chipOutlineHeight(lineHeight: lineHeight) / 2
        return (ceil(max(0, half - middle)), ceil(max(0, middle + half - lineHeight)))
    }

    /// The outline is three points taller than a line of the chip's text,
    /// and is drawn half a point inside this height.
    private static func chipOutlineHeight(lineHeight: CGFloat) -> CGFloat {
        lineHeight + 4
    }

    /// One rect for each line the chip is on, around that line's part of the
    /// chip. Enclosing rects of the whole range would run to the container's
    /// edge on every line but the last. The outline is drawn half a point
    /// inside the rect.
    func chipOutlineRects(forCharacterRange chipRange: NSRange) -> [NSRect] {
        guard let container = textContainers.first, let textStorage else { return [] }
        let glyphs = glyphRange(forCharacterRange: chipRange, actualCharacterRange: nil)
        var outlines: [NSRect] = []
        var lineStart = glyphs.location
        while lineStart < NSMaxRange(glyphs) {
            var lineGlyphs = NSRange()
            let line = lineFragmentRect(forGlyphAt: lineStart, effectiveRange: &lineGlyphs)
            guard lineGlyphs.length > 0 else { break }
            let piece = NSIntersectionRange(glyphs, lineGlyphs)
            let characterIndex = characterIndexForGlyph(at: piece.location)
            let font = characterIndex < textStorage.length
                ? textStorage.attribute(.font, at: characterIndex, effectiveRange: nil) as? NSFont
                : nil
            let baseline = line.minY + location(forGlyphAt: piece.location).y
            enumerateEnclosingRects(
                forGlyphRange: piece,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                // The rect also covers the line spacing below the text,
                // except on the last line. The outline centers on the
                // text and has the same height on every line.
                var outline = rect
                if let font {
                    outline.size.height = Self.chipOutlineHeight(lineHeight: self.defaultLineHeight(for: font))
                    outline.origin.y = Self.chipTextMiddle(baseline: baseline, font: font) - outline.size.height / 2
                }
                outlines.append(outline)
            }
            lineStart = NSMaxRange(lineGlyphs)
        }
        return outlines
    }

    /// The middle of a chip's capitals, in flipped coordinates. The chip's
    /// outline and spinner center on it, as the text and the dot do.
    static func chipTextMiddle(baseline: CGFloat, font: NSFont) -> CGFloat {
        baseline - font.capHeight / 2
    }

    /// No line break inside a chip, such as after a hyphen in its title. A
    /// chip wider than the line still wraps, because TextKit then breaks by
    /// character.
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        guard charIndex > 0, let textStorage = layoutManager.textStorage,
              charIndex < textStorage.length else { return true }
        return textStorage.attribute(.toasttyChip, at: charIndex, effectiveRange: nil) == nil
            || textStorage.attribute(.toasttyChip, at: charIndex - 1, effectiveRange: nil) == nil
    }

    /// The bar runs from the quote's first line to its last, like the bar
    /// beside a quote in its own view.
    private func drawQuoteBars(in characters: NSRange, textStorage: NSTextStorage, at origin: NSPoint) {
        let whole = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.toasttyQuote, in: characters) { value, range, _ in
            guard value != nil else { return }
            var quoteRange = NSRange()
            _ = textStorage.attribute(.toasttyQuote, at: range.location,
                                      longestEffectiveRange: &quoteRange, in: whole)
            let glyphs = glyphRange(forCharacterRange: quoteRange, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            let first = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            // The space below the last line belongs to the gap before the
            // next block. At the end of the text there is none.
            var bottom = last.maxY
            if NSMaxRange(quoteRange) < textStorage.length,
               let style = textStorage.attribute(.paragraphStyle, at: NSMaxRange(quoteRange) - 1,
                                                 effectiveRange: nil) as? NSParagraphStyle {
                bottom -= style.lineSpacing
            }
            let bar = NSRect(x: origin.x, y: origin.y + first.minY,
                             width: ToasttySelectableText.quoteBarWidth,
                             height: bottom - first.minY)
            NSColor(ConversationDesignTokens.border).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        }
    }
}
#endif
