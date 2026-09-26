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
            HoverTipHeader(dotColor: model.statusDotColorKind.color, name: model.name, tag: model.typeLabel)

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
        .hoverTipCardChrome()
    }
}

/// Row metadata the sidebar row itself stopped showing.
struct SessionRowHoverTipModel: Hashable {
    struct MetaItem: Hashable {
        let label: String
        let value: String
        /// Long values such as a scope list wrap instead of truncating.
        let wraps: Bool
        /// Set for values worth copying, such as a path; the row then shows a
        /// copy button.
        var copyValue: String? = nil
    }

    var name: String
    var agentLabel: String
    /// A custom tab title; automatic titles never reach the sidebar.
    var tabTitle: String?
    var statusDotColorKind: SessionChildHoverTipModel.StatusDotColorKind
    var bodyText: String?
    var turnStartedAt: Date?
    var metaItems: [MetaItem]
}

struct SessionRowHoverTipCard: View {
    let model: SessionRowHoverTipModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HoverTipHeader(dotColor: model.statusDotColorKind.color, name: model.name)

            if let bodyText = model.bodyText {
                // One line more than the row; the full text stays in the
                // session's own panel.
                SidebarView.styledSessionSummaryText(bodyText)
                    .lineSpacing(2)
                    .foregroundStyle(ToastyTheme.hoverTipBodyText)
                    .lineLimit(2)
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
                            HoverTipMetaRow(
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
                        HoverTipMetaRow(label: item.label, value: item.value, wraps: item.wraps, copyValue: item.copyValue)
                    }
                }
                .padding(.top, 6)
            }

            // The row no longer shows which tab or agent this is, so the
            // card closes on both.
            Rectangle()
                .fill(ToastyTheme.hoverTipDivider)
                .frame(height: 1)
                .padding(.top, 7)
            HStack(spacing: 6) {
                if let tabTitle = model.tabTitle {
                    HoverTipPill(text: tabTitle, style: .tab)
                }
                HoverTipPill(text: model.agentLabel, style: .agent)
                    .layoutPriority(1)
            }
            .padding(.top, 7)
        }
        .hoverTipCardChrome()
    }
}

/// A subspace row's hover card: every annotation under the name, as the
/// sidebar shows them under a workspace title, then its agent sessions as
/// compact rows shaped like the sidebar's session rows, then where the
/// subspace lives.
struct SubspaceHoverTipModel: Hashable {
    struct Session: Hashable {
        let title: String
        let panelID: UUID
        let agentLabel: String?
        let isUnread: Bool
        let railState: SidebarSessionPresentation.SessionRailState
        /// Approval and error only; the rail carries the other states.
        let badgeKind: SessionStatusKind?
        let turnStartedAt: Date?
        let summary: String?
    }

    struct Annotation: Hashable {
        let key: String
        let text: String
        let colorToken: AnnotationColorToken
    }

    var name: String
    var sessions: [Session]
    var hiddenSessionCount: Int
    var annotations: [Annotation]
    /// Display form, with the home directory shortened to `~`.
    var path: String?
    /// What the copy button copies.
    var absolutePath: String?
    var spawnerName: String?
}

struct SubspaceHoverTipCard: View {
    let model: SubspaceHoverTipModel
    /// Jumps to a session; the card closes afterwards.
    var onSelectSession: ((UUID) -> Void)? = nil

    @State private var hoveredSessionPanelID: UUID?

    private static let railWidth: CGFloat = 12
    private static let railGap: CGFloat = 6
    /// Room for the row hover fill, taken back outside so text still lines
    /// up with the header.
    private static let rowInset: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No status mark: each session line below shows its own, and a
            // combined one beside them would repeat it.
            HoverTipHeader(name: model.name, tag: "subspace")

            if model.annotations.isEmpty == false {
                // Text only: the card cannot be clicked, so no chip is a link.
                SidebarWrappingFlowLayout(horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(model.annotations, id: \.key) { annotation in
                        SidebarView.workspaceAnnotationChipLabel(
                            annotation: WorkspaceAnnotation(text: annotation.text),
                            chipColors: ToastyTheme.annotationChipColors(for: annotation.colorToken),
                            isLink: false
                        )
                    }
                }
                .padding(.bottom, 7)
            }

            if model.sessions.isEmpty {
                Text("No agent sessions")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ToastyTheme.hoverTipMutedText)
                    .padding(.bottom, 6)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(model.sessions.enumerated()), id: \.offset) { _, session in
                        selectableSessionRow(session)
                    }
                    if model.hiddenSessionCount > 0 {
                        Text("+\(model.hiddenSessionCount) more")
                            .font(ToastyTheme.fontWorkspaceSessionChildContext)
                            .foregroundStyle(ToastyTheme.sidebarChildContextText)
                            .padding(.leading, Self.railWidth + Self.railGap)
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 7)
            }

            if model.path != nil || model.spawnerName != nil {
                Rectangle()
                    .fill(ToastyTheme.hoverTipDivider)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 3) {
                    if let path = model.path {
                        // Cut from the front so the worktree name stays.
                        HoverTipMetaRow(
                            label: "path",
                            value: path,
                            truncationMode: .head,
                            copyValue: model.absolutePath
                        )
                    }
                    if let spawnerName = model.spawnerName {
                        HoverTipMetaRow(label: "spawner", value: spawnerName)
                    }
                }
                .padding(.top, 6)
            }
        }
        .hoverTipCardChrome()
    }

    @ViewBuilder
    private func selectableSessionRow(_ session: SubspaceHoverTipModel.Session) -> some View {
        if let onSelectSession {
            Button {
                let generation = HoverTipPresenter.shared.currentGeneration
                onSelectSession(session.panelID)
                HoverTipPresenter.shared.hide(generation: generation)
            } label: {
                sessionRow(session)
                    .padding(.horizontal, Self.rowInset)
                    .padding(.vertical, 2)
                    .background(
                        hoveredSessionPanelID == session.panelID ? ToastyTheme.hoverTipTagBackground : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -Self.rowInset)
            .onHover { isHovering in
                if isHovering {
                    hoveredSessionPanelID = session.panelID
                } else if hoveredSessionPanelID == session.panelID {
                    hoveredSessionPanelID = nil
                }
            }
            .accessibilityLabel("Go to \(session.title)")
            .background {
                SidebarSemanticTextBridge(text: "Go to \(session.title)")
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
        } else {
            sessionRow(session)
        }
    }

    private func sessionRow(_ session: SubspaceHoverTipModel.Session) -> some View {
        HStack(alignment: .top, spacing: Self.railGap) {
            SessionRailStatusIcon(state: session.railState)
                .frame(width: Self.railWidth, height: 15)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    SidebarView.styledSessionNameText(
                        session.title,
                        isEmphasized: session.isUnread || session.badgeKind != nil
                    )
                    .foregroundStyle(ToastyTheme.sidebarSessionAgentText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                    Spacer(minLength: 6)

                    if let agentLabel = session.agentLabel {
                        Text(agentLabel)
                            .font(ToastyTheme.fontWorkspaceSessionAgentLabel)
                            .foregroundStyle(ToastyTheme.sidebarChildContextText)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if let badgeKind = session.badgeKind {
                        SessionStatusBadge(kind: badgeKind)
                    }
                    if let turnStartedAt = session.turnStartedAt {
                        TimelineView(.periodic(from: turnStartedAt, by: 1)) { timeline in
                            Text(SidebarSessionPresentation.elapsedChildActivityText(
                                startedAt: turnStartedAt,
                                now: timeline.date
                            ))
                            .font(ToastyTheme.fontWorkspaceSessionElapsed)
                            .foregroundStyle(ToastyTheme.sidebarChildContextText)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                        }
                    }
                }
                .frame(minHeight: 15)

                if let summary = session.summary {
                    SidebarView.styledSessionSummaryText(summary)
                        .foregroundStyle(ToastyTheme.sidebarSummaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }
}

/// Status dot, name, and type tag across the top of a hover card. Cards
/// whose body already shows status leave out the dot.
private struct HoverTipHeader: View {
    var dotColor: Color? = nil
    let name: String
    var tag: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let dotColor {
                Circle()
                    .fill(dotColor.opacity(0.85))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }

            Text(name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(ToastyTheme.hoverTipText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if let tag {
                Text(tag)
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
        }
        .padding(.bottom, 4)
    }
}

/// The tab title and agent at the foot of a session card.
private struct HoverTipPill: View {
    enum Style {
        case tab
        case agent
    }

    let text: String
    let style: Style

    var body: some View {
        let (foreground, background, border): (Color, Color, Color) = switch style {
        case .tab:
            (ToastyTheme.hoverTipTabPillText, ToastyTheme.hoverTipTabPillBackground, ToastyTheme.hoverTipTabPillBorder)
        case .agent:
            (ToastyTheme.hoverTipAgentPillText, ToastyTheme.hoverTipAgentPillBackground, ToastyTheme.hoverTipAgentPillBorder)
        }
        Text(text)
            .font(style == .tab
                ? .system(size: 10.5, weight: .semibold)
                : .system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, style == .tab ? 7 : 6)
            .padding(.vertical, 1.5)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(border, lineWidth: 1)
            }
    }
}

/// A labeled line under a hover card's divider.
private struct HoverTipMetaRow: View {
    private static let labelColumnWidth: CGFloat = 56

    let label: String
    let value: String
    var wraps = false
    var truncationMode: Text.TruncationMode = .middle
    var copyValue: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(ToastyTheme.sidebarChildMetaText)
                .frame(width: Self.labelColumnWidth, alignment: .leading)

            Text(value)
                .foregroundStyle(ToastyTheme.hoverTipMutedText)
                .lineLimit(wraps ? 3 : 1)
                .truncationMode(wraps ? .tail : truncationMode)
                .fixedSize(horizontal: false, vertical: wraps)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let copyValue {
                HoverTipCopyButton(label: label, value: copyValue)
            }
        }
        .font(.system(size: 9.5, weight: .regular, design: .monospaced))
    }
}

/// Copies a card value, shows a check, then closes the card.
private struct HoverTipCopyButton: View {
    let label: String
    let value: String

    @State private var didCopy = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            didCopy = true
            let generation = HoverTipPresenter.shared.currentGeneration
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                HoverTipPresenter.shared.hide(generation: generation)
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(didCopy ? ToastyTheme.sessionReadyText : ToastyTheme.hoverTipMutedText)
                .frame(width: 16, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(didCopy ? "Copied" : "Copy \(label)")
        .background {
            SidebarSemanticTextBridge(text: didCopy ? "Copied \(label)" : "Copy \(label)")
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}

private extension View {
    func hoverTipCardChrome() -> some View {
        padding(.top, 8)
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
    /// How long a card stays up after the pointer leaves its row toward it, or
    /// leaves the card itself, so the pointer can cross the gap between them.
    nonisolated static let handoffGrace: TimeInterval = 0.2

    /// Test seam: the pointer's screen location when a row loses hover.
    static var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }

    private var panel: NSPanel?
    private var containerView: HoverTipContainerView?
    private var hostingView: NSHostingView<AnyView>?
    private var currentID: AnyHashable?
    private var currentAnchor: CGRect?
    /// Bumped on every show and hide, so a grace period started for one card
    /// never closes the card that replaced it.
    private var generation = 0
    private var isPointerInCard = false
    private var pendingHide: Task<Void, Never>?
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
        let panel = resolvedPanel()
        if currentID != id {
            generation += 1
            isPointerInCard = false
        }
        cancelPendingHide()
        let tipSize = layOut(content: content, in: panel)
        panel.setFrameOrigin(Self.tipOrigin(
            anchor: anchorScreenRect,
            tipSize: tipSize,
            visibleFrame: Self.visibleFrame(for: anchorScreenRect),
            placement: placement
        ))

        let shouldAnimate = panel.isVisible == false
            && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
        currentID = id
        currentAnchor = anchorScreenRect
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

    /// Replaces an open card's content without touching the hover handoff.
    /// While the pointer is on the card it keeps its top edge where it is,
    /// so a row re-sorting underneath does not pull the card away.
    func update<Content: View>(
        id: AnyHashable,
        content: Content,
        anchorScreenRect: CGRect,
        placement: HoverTipPlacement = .below
    ) {
        guard currentID == id, let panel, panel.isVisible else { return }
        let previousFrame = panel.frame
        let tipSize = layOut(content: content, in: panel)
        if isPointerInCard {
            let visibleFrame = Self.visibleFrame(for: anchorScreenRect)
            panel.setFrameOrigin(CGPoint(
                x: previousFrame.minX,
                y: max(visibleFrame.minY, previousFrame.maxY - tipSize.height)
            ))
        } else {
            panel.setFrameOrigin(Self.tipOrigin(
                anchor: anchorScreenRect,
                tipSize: tipSize,
                visibleFrame: Self.visibleFrame(for: anchorScreenRect),
                placement: placement
            ))
            currentAnchor = anchorScreenRect
        }
    }

    func hide(id: AnyHashable) {
        guard currentID == id else { return }
        hideAll()
    }

    /// Identifies the card on screen now, for work that should close only
    /// that card, such as a copy button's delayed close.
    var currentGeneration: Int { generation }

    func hide(generation: Int) {
        guard self.generation == generation else { return }
        hideAll()
    }

    /// The row lost hover. Leaving toward the card keeps it up for the grace
    /// period so the pointer can reach it; leaving any other way closes it.
    func anchorHoverEnded(id: AnyHashable) {
        guard currentID == id, let panel, panel.isVisible else { return }
        let headingToCard = currentAnchor.map { anchor in
            Self.isHeadingToCard(
                pointer: Self.pointerLocation(),
                anchor: anchor,
                card: panel.frame
            )
        } ?? false
        if headingToCard {
            scheduleHandoffHide()
        } else {
            hideAll()
        }
    }

    /// True while a card waits for the pointer to cross from its row. Another
    /// row hovered meanwhile waits out the grace before taking over, so a
    /// path to the card that clips a neighbor does not swap cards.
    func isHandingOff(awayFrom id: AnyHashable) -> Bool {
        pendingHide != nil && currentID != nil && currentID != id
    }

    func cardPointerChanged(inside: Bool) {
        guard currentID != nil else { return }
        isPointerInCard = inside
        if inside {
            cancelPendingHide()
        } else {
            scheduleHandoffHide()
        }
    }

    /// Whether the pointer left `anchor` through the side facing `card`,
    /// within the row's span on that side, and is still between the two.
    nonisolated static func isHeadingToCard(pointer: CGPoint, anchor: CGRect, card: CGRect) -> Bool {
        let tolerance: CGFloat = 2
        guard anchor.union(card).insetBy(dx: -tolerance, dy: -tolerance).contains(pointer) else {
            return false
        }
        let withinRowHeight = pointer.y >= anchor.minY - tolerance && pointer.y <= anchor.maxY + tolerance
        let withinSharedWidth = pointer.x >= max(anchor.minX, card.minX) - tolerance
            && pointer.x <= min(anchor.maxX, card.maxX) + tolerance
        if card.minX >= anchor.maxX - tolerance {
            return pointer.x >= anchor.maxX - tolerance && withinRowHeight
        }
        if card.maxY <= anchor.minY + tolerance {
            return pointer.y <= anchor.minY + tolerance && withinSharedWidth
        }
        if card.minY >= anchor.maxY - tolerance {
            return pointer.y >= anchor.maxY - tolerance && withinSharedWidth
        }
        return false
    }

    /// Which events close an open card. A left click on the card is its own
    /// (a row or copy button, or blank space that closes it on mouse-up);
    /// every other click, key, or scroll dismisses as before.
    nonisolated static func eventDismissesCard(_ type: NSEvent.EventType, isInCard: Bool) -> Bool {
        switch type {
        case .leftMouseDown:
            return isInCard == false
        case .rightMouseDown, .keyDown, .scrollWheel:
            return true
        default:
            return false
        }
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
        cancelPendingHide()
        generation += 1
        isPointerInCard = false
        currentID = nil
        currentAnchor = nil
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

    private func layOut<Content: View>(content: Content, in panel: NSPanel) -> CGSize {
        let rootView = AnyView(
            content
                .fixedSize(horizontal: false, vertical: true)
                // A click on blank card space closes the card; buttons in
                // the card take their own clicks first.
                .contentShape(Rectangle())
                .onTapGesture { HoverTipPresenter.shared.hideAll() }
                // The hosting view is reused, so give each shown card fresh
                // state (a copy check, a hovered row) rather than inheriting
                // the last card's. Refreshes keep the same generation.
                .id(generation)
        )
        let hostingView = resolvedHostingView(rootView: rootView)
        hostingView.rootView = rootView
        hostingView.layoutSubtreeIfNeeded()

        var tipSize = hostingView.fittingSize
        if tipSize.width <= 0 || tipSize.height <= 0 {
            tipSize = CGSize(width: 320, height: 72)
        }
        let containerView = resolvedContainerView(hostingView: hostingView)
        if panel.contentView !== containerView {
            panel.contentView = containerView
        }
        panel.setContentSize(tipSize)
        hostingView.frame = CGRect(origin: .zero, size: tipSize)
        return tipSize
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

    /// The panel's content view for its whole life, so pointer tracking
    /// survives the hosting view's content being replaced card to card.
    private func resolvedContainerView(hostingView: NSHostingView<AnyView>) -> HoverTipContainerView {
        if let containerView {
            return containerView
        }
        let containerView = HoverTipContainerView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(hostingView)
        containerView.onPointerInsideChanged = { [weak self] inside in
            self?.cardPointerChanged(inside: inside)
        }
        self.containerView = containerView
        return containerView
    }

    private func scheduleHandoffHide() {
        cancelPendingHide()
        let scheduledGeneration = generation
        pendingHide = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.handoffGrace * 1_000_000_000))
            guard let self, Task.isCancelled == false, self.generation == scheduledGeneration else { return }
            self.pendingHide = nil
            if self.isPointerInCard == false {
                self.hideAll()
            }
        }
    }

    private func cancelPendingHide() {
        pendingHide?.cancel()
        pendingHide = nil
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
        // Cards take the pointer so their rows and copy buttons can be
        // clicked. A borderless panel cannot become key, so clicking one never
        // moves keyboard focus off the terminal.
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let isInCard = event.window != nil && event.window === self.panel
                if Self.eventDismissesCard(event.type, isInCard: isInCard) {
                    self.hideAll()
                }
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
            HoverTipPresenter.shared.anchorHoverEnded(id: id)
        }
    }

    private func scheduleShow() {
        cancelPendingShow()
        let presenter = HoverTipPresenter.shared
        // A card already open (or just closed) means the pointer is scanning
        // the list, so swap immediately rather than re-running the warm-up,
        // unless the pointer may be on its way to the open card.
        let isHandingOff = presenter.isHandingOff(awayFrom: id)
        if presenter.isWarm, isHandingOff == false, let anchorScreenRect {
            showTip(anchorScreenRect: anchorScreenRect)
            return
        }
        let delayNanoseconds = isHandingOff
            ? UInt64(HoverTipPresenter.handoffGrace * 1_000_000_000)
            : Self.warmUpDelayNanoseconds
        hoverTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
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
    }

    private func hideTip() {
        HoverTipPresenter.shared.hide(id: id)
    }

    /// Keeps an open card current, including while the pointer is on the
    /// card rather than its row.
    private func refreshVisibleTip() {
        guard HoverTipPresenter.shared.isVisible(id: id) else { return }
        guard let anchorScreenRect else {
            hideTip()
            return
        }
        HoverTipPresenter.shared.update(
            id: id,
            content: tipContent(),
            anchorScreenRect: anchorScreenRect,
            placement: placement
        )
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
/// Reports the pointer entering and leaving the card, through a tracking
/// area that stays active while the app is frontmost but the card is not key.
final class HoverTipContainerView: NSView {
    var onPointerInsideChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerInsideChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerInsideChanged?(false)
    }
}

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
