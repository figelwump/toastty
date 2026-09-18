import AppKit
import CoreState
import SwiftUI

struct SessionChildHoverTipModel: Hashable {
    enum StatusDotColorKind: Hashable {
        case idle
        case working
        case needsApproval
        case ready
        case error

        init(statusKind: SessionStatusKind?) {
            switch statusKind ?? .idle {
            case .idle:
                self = .idle
            case .working:
                self = .working
            case .needsApproval:
                self = .needsApproval
            case .ready:
                self = .ready
            case .error:
                self = .error
            }
        }

        var color: Color {
            switch self {
            case .idle:
                return ToastyTheme.sessionIdleText
            case .working:
                return ToastyTheme.sessionIndicatorSpinnerColor
            case .needsApproval:
                return ToastyTheme.sessionNeedsApprovalText
            case .ready:
                return ToastyTheme.sessionReadyText
            case .error:
                return ToastyTheme.sessionErrorText
            }
        }
    }

    var name: String
    var typeLabel: String
    var statusDotColorKind: StatusDotColorKind
    var bodyText: String?
    var executionProfileText: String?
    var metaItems: [String]
}

struct SessionChildHoverTipCard: View {
    let model: SessionChildHoverTipModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.statusDotColorKind.color.opacity(0.85))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)

                Text(model.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ToastyTheme.hoverTipText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(model.typeLabel)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(ToastyTheme.hoverTipMutedText)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(ToastyTheme.hoverTipTagBackground)
                    )
            }
            .padding(.bottom, 4)

            if let bodyText = model.bodyText {
                Text(bodyText)
                    .font(.system(size: 11, weight: .regular))
                    .lineSpacing(1.5)
                    .foregroundStyle(ToastyTheme.hoverTipBodyText)
                    .lineLimit(6)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
            }

            if let executionProfileText = model.executionProfileText {
                Text(executionProfileText)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(ToastyTheme.hoverTipMutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.bottom, 5)
            }

            if model.metaItems.isEmpty == false {
                Rectangle()
                    .fill(ToastyTheme.hoverTipDivider)
                    .frame(height: 1)

                HStack(spacing: 10) {
                    ForEach(Array(model.metaItems.enumerated()), id: \.offset) { _, item in
                        Text(item)
                            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(ToastyTheme.hoverTipMutedText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.top, 5)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 10)
        .padding(.bottom, 7)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(ToastyTheme.hoverTipBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(ToastyTheme.hoverTipBorder, lineWidth: 1)
        }
    }
}

/// Row metadata the sidebar row itself stopped showing.
struct SessionRowHoverTipModel: Hashable {
    struct MetaItem: Hashable {
        let label: String
        let value: String
        /// Long values such as a scope list wrap instead of truncating.
        let wraps: Bool
    }

    var name: String
    var agentLabel: String
    var statusDotColorKind: SessionChildHoverTipModel.StatusDotColorKind
    var bodyText: String?
    var turnStartedAt: Date?
    var metaItems: [MetaItem]
}

struct SessionRowHoverTipCard: View {
    let model: SessionRowHoverTipModel

    private static let labelColumnWidth: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.statusDotColorKind.color.opacity(0.85))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)

                Text(model.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ToastyTheme.hoverTipText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(model.agentLabel)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(ToastyTheme.hoverTipMutedText)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(ToastyTheme.hoverTipTagBackground)
                    )
            }
            .padding(.bottom, 4)

            if let bodyText = model.bodyText {
                // The row truncates the summary to one line; the card is where
                // the rest of it lives.
                Text(SidebarSessionPresentation.sessionSummaryAttributedText(bodyText))
                    .font(.system(size: 11, weight: .regular))
                    .lineSpacing(1.5)
                    .foregroundStyle(ToastyTheme.hoverTipBodyText)
                    .lineLimit(6)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
            }

            if model.metaItems.isEmpty == false || model.turnStartedAt != nil {
                Rectangle()
                    .fill(ToastyTheme.hoverTipDivider)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 3) {
                    if let turnStartedAt = model.turnStartedAt {
                        TimelineView(.periodic(from: turnStartedAt, by: 1)) { timeline in
                            metaRow(
                                label: "elapsed",
                                value: SidebarSessionPresentation.elapsedChildActivityText(
                                    startedAt: turnStartedAt,
                                    now: timeline.date
                                ),
                                wraps: false
                            )
                        }
                    }

                    ForEach(Array(model.metaItems.enumerated()), id: \.offset) { _, item in
                        metaRow(label: item.label, value: item.value, wraps: item.wraps)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 10)
        .padding(.bottom, 7)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(ToastyTheme.hoverTipBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(ToastyTheme.hoverTipBorder, lineWidth: 1)
        }
    }

    private func metaRow(label: String, value: String, wraps: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(ToastyTheme.sidebarChildMetaText)
                .frame(width: Self.labelColumnWidth, alignment: .leading)

            Text(value)
                .foregroundStyle(ToastyTheme.hoverTipMutedText)
                .lineLimit(wraps ? 3 : 1)
                .truncationMode(wraps ? .tail : .middle)
                .fixedSize(horizontal: false, vertical: wraps)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 9.5, weight: .regular, design: .monospaced))
    }
}

/// Where a tip opens relative to its anchor.
enum HoverTipPlacement: Equatable {
    /// Below the anchor, flipping above when there is no room. Correct for a
    /// tip anchored to something the surrounding content does not need.
    case below
    /// Beside the anchor's trailing edge, level with it. A sidebar card opens
    /// over the terminal this way instead of covering the rows being scanned.
    /// Falls back to `below` when the card does not fit beside the anchor.
    case trailing(gap: CGFloat)
}

@MainActor
final class HoverTipPresenter {
    static let shared = HoverTipPresenter()

    private nonisolated static let anchorGap: CGFloat = 6
    /// After a card closes, a card on another row opens immediately instead of
    /// waiting out the warm-up again, so scanning down a list does not stutter.
    private nonisolated static let warmWindow: TimeInterval = 0.35

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var currentID: AnyHashable?
    private var lastHiddenAt: Date?
    private var eventMonitor: Any?
    private var deactivationObserver: NSObjectProtocol?

    private init() {}

    func show<Content: View>(
        id: AnyHashable,
        content: Content,
        anchorScreenRect: CGRect,
        placement: HoverTipPlacement = .below
    ) {
        let rootView = AnyView(content.fixedSize(horizontal: false, vertical: true))
        let hostingView = resolvedHostingView(rootView: rootView)
        hostingView.rootView = rootView
        hostingView.layoutSubtreeIfNeeded()

        var tipSize = hostingView.fittingSize
        if tipSize.width <= 0 || tipSize.height <= 0 {
            tipSize = CGSize(width: 320, height: 72)
        }
        hostingView.frame = CGRect(origin: .zero, size: tipSize)

        let panel = resolvedPanel()
        if panel.contentView !== hostingView {
            panel.contentView = hostingView
        }
        panel.setContentSize(tipSize)
        panel.setFrameOrigin(Self.tipOrigin(
            anchor: anchorScreenRect,
            tipSize: tipSize,
            visibleFrame: Self.visibleFrame(for: anchorScreenRect),
            placement: placement
        ))

        let shouldAnimate = panel.isVisible == false
            && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
        currentID = id
        installEventMonitorIfNeeded()
        installDeactivationObserverIfNeeded()

        if shouldAnimate {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    func hide(id: AnyHashable) {
        guard currentID == id else { return }
        hideAll()
    }

    /// True while a card is open or just closed. A hover that lands inside
    /// this window presents without the warm-up delay.
    var isWarm: Bool {
        if panel?.isVisible == true, currentID != nil {
            return true
        }
        guard let lastHiddenAt else { return false }
        return Date().timeIntervalSince(lastHiddenAt) < Self.warmWindow
    }

    func hideAll() {
        if panel?.isVisible == true {
            lastHiddenAt = Date()
        }
        currentID = nil
        panel?.alphaValue = 1
        panel?.orderOut(nil)
        removeEventMonitor()
        removeDeactivationObserver()
    }

    func isVisible(id: AnyHashable) -> Bool {
        currentID == id && panel?.isVisible == true
    }

    nonisolated static func tipOrigin(
        anchor: CGRect,
        tipSize: CGSize,
        visibleFrame: CGRect,
        placement: HoverTipPlacement = .below
    ) -> CGPoint {
        if case .trailing(let gap) = placement,
           let besideOrigin = trailingTipOrigin(
               anchor: anchor,
               tipSize: tipSize,
               visibleFrame: visibleFrame,
               gap: gap
           ) {
            return besideOrigin
        }

        let maximumX = visibleFrame.maxX - tipSize.width
        let x = clamped(
            anchor.minX,
            minimum: visibleFrame.minX,
            maximum: maximumX
        )

        let belowY = anchor.minY - anchorGap - tipSize.height
        var y = belowY
        if belowY < visibleFrame.minY {
            y = anchor.maxY + anchorGap
            if y + tipSize.height > visibleFrame.maxY {
                y = max(visibleFrame.minY, visibleFrame.maxY - tipSize.height)
            }
        }

        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// Level with the anchor's top edge, clamped into the screen. Returns
    /// `nil` when the card does not fit beside the anchor, so the caller can
    /// fall back to the below-anchor placement.
    private nonisolated static func trailingTipOrigin(
        anchor: CGRect,
        tipSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat
    ) -> CGPoint? {
        let x = anchor.maxX + gap
        guard x >= visibleFrame.minX,
              x + tipSize.width <= visibleFrame.maxX else {
            return nil
        }
        let y = clamped(
            anchor.maxY - tipSize.height,
            minimum: visibleFrame.minY,
            maximum: visibleFrame.maxY - tipSize.height
        )
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    private func resolvedHostingView(rootView: AnyView) -> NSHostingView<AnyView> {
        if let hostingView {
            return hostingView
        }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = false
        hostingView.setAccessibilityElement(false)
        self.hostingView = hostingView
        return hostingView
    }

    private func resolvedPanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        self.panel = panel
        return panel
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            Task { @MainActor in
                self?.hideAll()
            }
            return event
        }
    }

    private func installDeactivationObserverIfNeeded() {
        guard deactivationObserver == nil else { return }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hideAll()
            }
        }
    }

    private func removeEventMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func removeDeactivationObserver() {
        guard let deactivationObserver else { return }
        NotificationCenter.default.removeObserver(deactivationObserver)
        self.deactivationObserver = nil
    }

    private static func visibleFrame(for anchor: CGRect) -> CGRect {
        let visibleFrames = NSScreen.screens
            .map(\.visibleFrame)
            .filter { $0.isNull == false && $0.isEmpty == false }
        guard visibleFrames.isEmpty == false else {
            return NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        }

        let anchorCenter = CGPoint(x: anchor.midX, y: anchor.midY)
        if let containingFrame = visibleFrames.first(where: { $0.contains(anchorCenter) }) {
            return containingFrame
        }

        return visibleFrames.max { lhs, rhs in
            let lhsArea = intersectionArea(between: anchor, and: lhs)
            let rhsArea = intersectionArea(between: anchor, and: rhs)
            if abs(lhsArea - rhsArea) >= 0.5 {
                return lhsArea < rhsArea
            }
            return squaredDistance(from: anchorCenter, to: lhs)
                > squaredDistance(from: anchorCenter, to: rhs)
        } ?? visibleFrames[0]
    }

    private nonisolated static func clamped(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        guard maximum >= minimum else { return minimum }
        return min(max(value, minimum), maximum)
    }

    private static func intersectionArea(between lhs: CGRect, and rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        guard intersection.isNull == false, intersection.isEmpty == false else {
            return 0
        }
        return intersection.width * intersection.height
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> Double {
        let closestX = min(max(point.x, rect.minX), rect.maxX)
        let closestY = min(max(point.y, rect.minY), rect.maxY)
        let deltaX = point.x - closestX
        let deltaY = point.y - closestY
        return deltaX * deltaX + deltaY * deltaY
    }
}

extension View {
    /// `isHovering` supplies the hover state from outside. Pass it when an
    /// AppKit overlay owns hit-testing for this view, because SwiftUI's own
    /// `.onHover` never fires underneath one. Omit it otherwise.
    func hoverTip<TipContent: View>(
        id: AnyHashable,
        refreshID: AnyHashable? = nil,
        placement: HoverTipPlacement = .below,
        isHovering: Bool? = nil,
        @ViewBuilder content: @escaping () -> TipContent
    ) -> some View {
        modifier(
            HoverTipModifier(
                id: id,
                refreshID: refreshID,
                placement: placement,
                externalHoverState: isHovering,
                tipContent: content
            )
        )
    }
}

private struct HoverTipModifier<TipContent: View>: ViewModifier {
    static var warmUpDelayNanoseconds: UInt64 { 350_000_000 }

    let id: AnyHashable
    let refreshID: AnyHashable?
    let placement: HoverTipPlacement
    let externalHoverState: Bool?
    let tipContent: () -> TipContent

    @State private var hoverTask: Task<Void, Never>?
    @State private var anchorScreenRect: CGRect?
    @State private var isHovering = false
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .background {
                HoverTipAnchor { rect in
                    anchorScreenRect = rect
                }
                .allowsHitTesting(false)
            }
            .modifier(
                HoverTipStateSource(
                    externalHoverState: externalHoverState,
                    onHoverStateChanged: updateHoverState
                )
            )
            .onChange(of: anchorScreenRect) { _, _ in
                refreshVisibleTip()
            }
            .onChange(of: refreshID) { _, _ in
                refreshVisibleTip()
            }
            .onDisappear {
                cancelPendingShow()
                hideTip()
            }
    }

    private func updateHoverState(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            scheduleShow()
        } else {
            cancelPendingShow()
            hideTip()
        }
    }

    private func scheduleShow() {
        cancelPendingShow()
        // A card already open (or just closed) means the pointer is scanning
        // the list, so swap immediately rather than re-running the warm-up.
        if HoverTipPresenter.shared.isWarm, let anchorScreenRect {
            showTip(anchorScreenRect: anchorScreenRect)
            return
        }
        hoverTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.warmUpDelayNanoseconds)
            } catch {
                return
            }
            guard Task.isCancelled == false,
                  isHovering,
                  let anchorScreenRect else {
                return
            }
            showTip(anchorScreenRect: anchorScreenRect)
            hoverTask = nil
        }
    }

    private func cancelPendingShow() {
        hoverTask?.cancel()
        hoverTask = nil
    }

    private func showTip(anchorScreenRect: CGRect) {
        HoverTipPresenter.shared.show(
            id: id,
            content: tipContent(),
            anchorScreenRect: anchorScreenRect,
            placement: placement
        )
        isPresented = true
    }

    private func hideTip() {
        HoverTipPresenter.shared.hide(id: id)
        isPresented = false
    }

    private func refreshVisibleTip() {
        guard isHovering, isPresented else { return }
        guard HoverTipPresenter.shared.isVisible(id: id) else {
            isPresented = false
            return
        }
        guard let anchorScreenRect else {
            hideTip()
            return
        }
        showTip(anchorScreenRect: anchorScreenRect)
    }
}

/// Hover either comes from SwiftUI or from the caller. Keeping the two in one
/// modifier would leave a dead `.onHover` attached in the external case, and a
/// dead `.onHover` still competes for hit-testing.
private struct HoverTipStateSource: ViewModifier {
    let externalHoverState: Bool?
    let onHoverStateChanged: (Bool) -> Void

    func body(content: Content) -> some View {
        if let externalHoverState {
            content
                .onChange(of: externalHoverState, initial: true) { _, hovering in
                    onHoverStateChanged(hovering)
                }
        } else {
            content.onHover { hovering in
                onHoverStateChanged(hovering)
            }
        }
    }
}

private struct HoverTipAnchor: NSViewRepresentable {
    let onScreenRectChange: @MainActor (CGRect?) -> Void

    func makeNSView(context: Context) -> HoverTipAnchorView {
        let view = HoverTipAnchorView()
        view.onScreenRectChange = onScreenRectChange
        view.scheduleReport()
        return view
    }

    func updateNSView(_ nsView: HoverTipAnchorView, context: Context) {
        nsView.onScreenRectChange = onScreenRectChange
        nsView.scheduleReport()
    }
}

@MainActor
private final class HoverTipAnchorView: NSView {
    var onScreenRectChange: (@MainActor (CGRect?) -> Void)?
    private var lastScreenRect: CGRect?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleReport()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleReport()
    }

    override func layout() {
        super.layout()
        reportScreenRect()
    }

    func scheduleReport() {
        Task { @MainActor [weak self] in
            self?.reportScreenRect()
        }
    }

    private func reportScreenRect() {
        guard let window else {
            if lastScreenRect != nil {
                lastScreenRect = nil
                onScreenRectChange?(nil)
            }
            return
        }

        let rectInWindow = convert(bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        guard screenRect != lastScreenRect else { return }
        lastScreenRect = screenRect
        onScreenRectChange?(screenRect)
    }
}
