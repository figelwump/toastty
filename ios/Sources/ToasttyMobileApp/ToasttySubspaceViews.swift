import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain
import UIKit

/// Which Subspaces groups the user collapsed, kept across launches so a long
/// list of finished tasks stays folded away.
struct ToasttyCollapsedSubspaceGroups: Equatable {
    static let preferenceKey = "toastty-mobile-collapsed-subspace-groups"

    private(set) var parentIDs: Set<UUID>

    init(storedValue: String) {
        parentIDs = Set(storedValue.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    var storedValue: String {
        parentIDs.map(\.uuidString).sorted().joined(separator: ",")
    }

    func contains(_ parentID: UUID) -> Bool { parentIDs.contains(parentID) }

    mutating func set(_ parentID: UUID, collapsed: Bool) {
        if collapsed {
            parentIDs.insert(parentID)
        } else {
            parentIDs.remove(parentID)
        }
    }
}

enum ToasttySubspaceGroupPresentation {
    /// The rows a group lists for a ⑂ filter. The filter gives way when it
    /// would hide a subspace that needs approval or has an error, the same
    /// rule that reopens a collapsed group.
    static func rows(
        _ rows: [MobileSubspaceRow],
        spawnedBy conversationID: UUID?
    ) -> (rows: [MobileSubspaceRow], isFiltered: Bool) {
        guard let conversationID else { return (rows, false) }
        let hidesAttention = rows.contains {
            $0.workspace.spawningConversationID != conversationID && needsAttention($0.status)
        }
        guard hidesAttention == false else { return (rows, false) }
        return (rows.filter { $0.workspace.spawningConversationID == conversationID }, true)
    }

    static func needsAttention(_ status: MobileSubspaceStatus) -> Bool {
        status == .needsApproval || status == .error
    }

    static func countLabel(shown: Int, total: Int) -> String {
        shown == total ? "\(total)" : "\(shown)/\(total)"
    }

    static func statusLabel(_ status: MobileSubspaceStatus) -> String {
        switch status {
        case .ready: "ready"
        case .needsApproval: "needs approval"
        case .error: "error"
        case .working: "working"
        case .idle: "idle"
        case .done: "done"
        }
    }

    static func doneActionTitle(isDone: Bool) -> String {
        isDone ? "Mark as Not Done" : "Mark as Done"
    }
}

/// The Subspaces group under a workspace: a collapsible header with a count
/// and a tally of the rows that want the user, then one row per subspace.
struct ToasttySubspaceGroup: View {
    let parent: MobileWorkspace
    /// Rows the session filter lists, before any ⑂ filter.
    let rows: [MobileSubspaceRow]
    let total: Int
    let controller: HomeScreenController
    @Binding var spawnerFilter: ToasttySpawnerChip?
    let openWorkspace: (UUID) -> Void

    @AppStorage(ToasttyCollapsedSubspaceGroups.preferenceKey) private var storedCollapsedGroups = ""

    var body: some View {
        let listed = ToasttySubspaceGroupPresentation.rows(rows, spawnedBy: activeFilter?.conversationID)
        VStack(spacing: 2) {
            header(shown: listed.rows.count)
            if isExpanded {
                if listed.isFiltered, let activeFilter {
                    filterBar(activeFilter)
                }
                ForEach(listed.rows) { row in
                    ToasttySubspaceRow(
                        row: row,
                        parentTitle: parent.title,
                        controller: controller,
                        openWorkspace: openWorkspace
                    )
                }
            }
        }
    }

    private var activeFilter: ToasttySpawnerChip? {
        spawnerFilter?.parentWorkspaceID == parent.id ? spawnerFilter : nil
    }

    /// A collapsed group reopens while a subspace needs approval or has an
    /// error, as on the desktop.
    private var isExpanded: Bool {
        ToasttyCollapsedSubspaceGroups(storedValue: storedCollapsedGroups).contains(parent.id) == false
            || rows.contains { ToasttySubspaceGroupPresentation.needsAttention($0.status) }
    }

    private func header(shown: Int) -> some View {
        Button {
            // Toggles the user's choice, which is not always what shows: a
            // group held open for a subspace that needs them folds once
            // nothing does.
            var groups = ToasttyCollapsedSubspaceGroups(storedValue: storedCollapsedGroups)
            groups.set(parent.id, collapsed: groups.contains(parent.id) == false)
            storedCollapsedGroups = groups.storedValue
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .imageScale(.small)
                    .frame(width: 12)
                Text("SUBSPACES")
                    .tracking(0.8)
                Text(ToasttySubspaceGroupPresentation.countLabel(shown: shown, total: total))
                Spacer(minLength: 8)
                tally
            }
            .font(.caption2.monospaced())
            .foregroundStyle(ToasttyDesignTokens.mutedText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(headerAccessibilityLabel(shown: shown))
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("toastty-subspaces-group-\(parent.id.uuidString)")
    }

    private var tallyCounts: [(status: MobileSubspaceStatus, count: Int)] {
        [MobileSubspaceStatus.ready, .needsApproval, .error].compactMap { status in
            let count = rows.filter { $0.status == status }.count
            return count == 0 ? nil : (status, count)
        }
    }

    private var tally: some View {
        HStack(spacing: 6) {
            ForEach(tallyCounts, id: \.status) { entry in
                HStack(spacing: 3) {
                    Circle()
                        .fill(ToasttySubspaceStatusStyle.color(entry.status, freshness: controller.freshness))
                        .frame(width: 6, height: 6)
                    Text("\(entry.count)")
                }
            }
        }
    }

    private func headerAccessibilityLabel(shown: Int) -> String {
        (["Subspaces", ToasttySubspaceGroupPresentation.countLabel(shown: shown, total: total)]
            + tallyCounts.map { "\($0.count) \(ToasttySubspaceGroupPresentation.statusLabel($0.status))" })
            .joined(separator: ", ")
    }

    private func filterBar(_ filter: ToasttySpawnerChip) -> some View {
        let name = controller.conversation(id: filter.conversationID)
            .map(ToasttySessionRowPresentation.title(for:)) ?? "this session"
        return Button {
            spawnerFilter = nil
        } label: {
            HStack(spacing: 6) {
                Text("Only subspaces from \(name)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .font(.caption2)
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(ToasttyDesignTokens.chipSurface, in: ToasttySessionRow.shape)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Only subspaces from \(name)")
        .accessibilityHint("Shows all subspaces")
        .accessibilityIdentifier("toastty-subspaces-filter-clear")
    }
}

enum ToasttySubspaceStatusStyle {
    static func color(_ status: MobileSubspaceStatus, freshness: LiveProjectionFreshness) -> Color {
        guard freshness == .live else { return ToasttyDesignTokens.mutedText }
        return switch status {
        case .ready, .done: ToasttyDesignTokens.color(for: .ready)
        case .needsApproval: ToasttyDesignTokens.color(for: .needsApproval)
        case .error: ToasttyDesignTokens.color(for: .error)
        case .working: ToasttyDesignTokens.color(for: .working)
        case .idle: ToasttyDesignTokens.mutedText
        }
    }

    static func rowTint(_ status: MobileSubspaceStatus) -> Color {
        switch status {
        case .ready: ToasttyDesignTokens.color(for: .ready).opacity(0.16)
        case .needsApproval: ToasttyDesignTokens.color(for: .needsApproval).opacity(0.13)
        case .error: ToasttyDesignTokens.color(for: .error).opacity(0.13)
        case .working, .idle, .done: .clear
        }
    }
}

/// A subspace's status mark. Subspaces use squares where sessions use dots,
/// and the quiet square doubles as the done checkbox.
struct ToasttySubspaceRailMark: View {
    let status: MobileSubspaceStatus
    let freshness: LiveProjectionFreshness

    private static let boxSize: CGFloat = 15

    var body: some View {
        let color = ToasttySubspaceStatusStyle.color(status, freshness: freshness)
        switch status {
        case .working:
            if freshness == .live {
                ToasttySpinner(size: 10, color: color)
            } else {
                square(color)
            }
        case .needsApproval, .error:
            square(color)
                .background {
                    if status == .needsApproval, freshness == .live {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color.opacity(0.22))
                            .frame(width: 15, height: 15)
                    }
                }
        case .idle:
            box.strokeBorder(ToasttyDesignTokens.mutedText, lineWidth: 1.4)
                .frame(width: Self.boxSize, height: Self.boxSize)
        case .ready:
            box.strokeBorder(color, lineWidth: 1.6)
                .frame(width: Self.boxSize, height: Self.boxSize)
        case .done:
            box.fill(color.opacity(0.22))
                .overlay { box.strokeBorder(color.opacity(0.55), lineWidth: 1.2) }
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(color)
                }
                .frame(width: Self.boxSize, height: Self.boxSize)
        }
    }

    private var box: RoundedRectangle {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
    }

    private func square(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 8, height: 8)
    }
}

/// One subspace under its parent: the status mark, the title with its badge
/// and chip, and the summary of the session that sets the status. Tapping
/// the row opens the subspace; tapping a quiet row's box marks it done.
struct ToasttySubspaceRow: View {
    let row: MobileSubspaceRow
    let parentTitle: String
    let controller: HomeScreenController
    let openWorkspace: (UUID) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let railWidth: CGFloat = 16

    var body: some View {
        ZStack(alignment: .leading) {
            Button {
                openWorkspace(row.id)
            } label: {
                label
            }
            .buttonStyle(ToasttySessionRowButtonStyle(tint: ToasttySubspaceStatusStyle.rowTint(row.status)))
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Opens the subspace. Touch and hold for details.")
            .accessibilityIdentifier("toastty-subspace-row-\(row.id.uuidString)")
            if showsDoneToggle {
                // The box is small; its button covers the row's leading
                // edge so it is an easy target.
                Button(action: toggleDone) {
                    Color.clear
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ToasttySubspaceGroupPresentation.doneActionTitle(isDone: row.workspace.isDone))
                .accessibilityValue(row.workspace.title)
                .accessibilityIdentifier("toastty-subspace-done-\(row.id.uuidString)")
            }
        }
        .contextMenu {
            Button("Open Subspace", systemImage: "arrow.up.right") {
                openWorkspace(row.id)
            }
            if showsDoneToggle {
                Button(
                    ToasttySubspaceGroupPresentation.doneActionTitle(isDone: row.workspace.isDone),
                    systemImage: row.workspace.isDone ? "square" : "checkmark.square",
                    action: toggleDone
                )
            }
        } preview: {
            ToasttySubspaceDetailCard(
                row: row,
                parentTitle: parentTitle,
                spawnerTitle: row.workspace.spawningConversationID
                    .flatMap(controller.conversation(id:))
                    .map(ToasttySessionRowPresentation.title(for:)),
                freshness: controller.freshness
            )
        }
    }

    /// The box is a checkbox only while the row is quiet and the Mac will
    /// take the change; otherwise it is just the row's status mark.
    private var showsDoneToggle: Bool {
        row.status.showsDoneToggle && controller.canMarkSubspacesDone
    }

    private func toggleDone() {
        controller.setSubspaceDone(row.id, isDone: !row.workspace.isDone)
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(" ")
                .font(titleFont)
                .frame(width: Self.railWidth)
                .overlay {
                    ToasttySubspaceRailMark(status: row.status, freshness: controller.freshness)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                if let summary = row.summary {
                    Text(summary)
                        .font(row.status == .working ? .caption.monospaced().italic() : .caption.monospaced())
                        .foregroundStyle(row.status == .done
                            ? ToasttyDesignTokens.mutedText
                            : ToasttyDesignTokens.secondaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(ToasttySessionRow.shape)
    }

    @ViewBuilder
    private var titleLine: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) {
                titleText
                HStack(spacing: 6) { trailingFacts }
            }
        } else {
            // The title is laid out first and the chip takes what is left,
            // so a long chip shortens before the subspace's name does.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                titleText
                    .layoutPriority(1)
                trailingFacts
            }
        }
    }

    private var titleText: some View {
        Text(row.workspace.title)
            .font(titleFont)
            .foregroundStyle(row.status == .done
                ? ToasttyDesignTokens.mutedText
                : ToasttyDesignTokens.primaryText)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var trailingFacts: some View {
        if let badge = badge {
            let color = ToasttySubspaceStatusStyle.color(row.status, freshness: controller.freshness)
            Text(badge)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
        }
        if dynamicTypeSize.isAccessibilitySize == false {
            Spacer(minLength: 0)
        }
        if let chip = row.chip {
            ToasttyAnnotationChip(
                annotation: RemoteWorkspaceAnnotation(key: chip.key, text: chip.text, color: chip.color),
                size: .compact
            )
            .frame(minWidth: 44, maxWidth: 110, alignment: .trailing)
            .opacity(row.status == .done ? 0.7 : 1)
        }
        Image(systemName: "arrow.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(ToasttyDesignTokens.mutedText)
            .accessibilityHidden(true)
    }

    private var badge: String? {
        switch row.status {
        case .needsApproval: "approval"
        case .error: "error"
        case .ready, .working, .idle, .done: nil
        }
    }

    private var titleFont: Font {
        let weight: Font.Weight = switch row.status {
        case .ready, .needsApproval, .error: .bold
        case .working, .idle: .medium
        case .done: .regular
        }
        let font = Font.subheadline.weight(weight)
        return row.status == .working ? font.italic() : font
    }

    private var accessibilityLabel: String {
        let status = controller.freshness == .live
            ? ToasttySubspaceGroupPresentation.statusLabel(row.status)
            : "last seen \(ToasttySubspaceGroupPresentation.statusLabel(row.status))"
        return ([row.workspace.title, "subspace", status, row.summary]
            + [row.chip.map(ToasttyWorkspaceAnnotationAccessibility.label(for:))])
            .compactMap { $0 }
            .filter { $0.isEmpty == false }
            .joined(separator: ", ")
    }
}

/// The long-press card for a subspace, the phone's version of the desktop
/// subspace hover card.
struct ToasttySubspaceDetailCard: View {
    let row: MobileSubspaceRow
    let parentTitle: String
    let spawnerTitle: String?
    let freshness: LiveProjectionFreshness

    private static let listedSessions = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(" ")
                    .font(.headline)
                    .frame(width: 16)
                    .overlay { ToasttySubspaceRailMark(status: row.status, freshness: freshness) }
                Text(row.workspace.title)
                    .font(.headline)
                    .foregroundStyle(ToasttyDesignTokens.primaryText)
                    .lineLimit(2)
                Text("subspace")
                    .font(.caption2.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
            }
            if !row.workspace.annotations.isEmpty {
                ToasttyChipFlowLayout(spacing: 5, lineSpacing: 5, maximumItemWidth: 200) {
                    ForEach(row.workspace.annotations, id: \.key) { annotation in
                        ToasttyAnnotationChip(
                            annotation: RemoteWorkspaceAnnotation(
                                key: annotation.key, text: annotation.text, color: annotation.color
                            ),
                            size: .compact
                        )
                    }
                }
            }
            divider
            sessions
            divider
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                fact("status", ToasttySubspaceGroupPresentation.statusLabel(row.status))
                fact("parent", parentTitle)
                if let path = row.workspace.sortedConversations.lazy.compactMap(\.cwd).first {
                    fact("path", path, lineLimit: 1, truncation: .head)
                }
                if let spawnerTitle {
                    fact("spawner", spawnerTitle)
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(ToasttyDesignTokens.elevatedSurface)
    }

    @ViewBuilder
    private var sessions: some View {
        let conversations = row.workspace.sortedConversations
        if conversations.isEmpty {
            Text("No agent sessions")
                .font(.caption)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(conversations.prefix(Self.listedSessions)) { conversation in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(" ")
                            .font(.caption.weight(.semibold))
                            .frame(width: 12)
                            .overlay {
                                ToasttySessionRailMark(bucket: conversation.state.bucket, freshness: freshness)
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(ToasttySessionRowPresentation.title(for: conversation))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(ToasttyDesignTokens.primaryText)
                                    .lineLimit(1)
                                Text(conversation.agent.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                            }
                            Text(conversation.lastActivity)
                                .font(.caption2.monospaced())
                                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }
                if conversations.count > Self.listedSessions {
                    Text("+\(conversations.count - Self.listedSessions) more")
                        .font(.caption2)
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(ToasttyDesignTokens.divider)
            .frame(height: 1)
    }

    private func fact(
        _ label: String,
        _ value: String,
        lineLimit: Int? = 3,
        truncation: Text.TruncationMode = .tail
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
            Text(value)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .lineLimit(lineLimit)
                .truncationMode(truncation)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.monospaced())
    }
}

/// The message after a done change, with Undo in place of the desktop's
/// hover preview: a stray tap is easier on glass than a stray click.
struct ToasttySubspaceDoneNoticeModifier: ViewModifier {
    let controller: HomeScreenController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let visibleDuration: Duration = .seconds(5)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let notice = controller.subspaceDoneNotice {
                    noticeView(notice)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: notice.id) {
                            try? await Task.sleep(for: Self.visibleDuration)
                            guard Task.isCancelled == false else { return }
                            controller.dismissSubspaceDoneNotice(notice)
                        }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controller.subspaceDoneNotice)
            .sensoryFeedback(trigger: controller.subspaceDoneNotice) { _, notice in
                switch notice?.kind {
                case .changed?: .success
                case .failed?: .error
                case nil: nil
                }
            }
    }

    private func noticeView(_ notice: SubspaceDoneNotice) -> some View {
        HStack(spacing: 12) {
            Text(notice.message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ToasttyDesignTokens.inkOnAmber)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("toastty-subspace-done-notice")
            if notice.canUndo {
                Button("Undo", action: controller.undoSubspaceDoneNotice)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(ToasttyDesignTokens.inkOnAmber)
                    .underline()
                    .frame(minWidth: 44, minHeight: 32)
                    .accessibilityIdentifier("toastty-subspace-done-undo")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(ToasttyDesignTokens.userBubbleText, in: Capsule())
        .shadow(color: .black.opacity(0.45), radius: 7, y: 3)
    }
}

extension View {
    func toasttySubspaceDoneNotice(_ controller: HomeScreenController) -> some View {
        modifier(ToasttySubspaceDoneNoticeModifier(controller: controller))
    }
}
