import ConversationUI
import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

/// Where a card's To ship line or Done count sends the user in the Tasks
/// tab.
enum ToasttyTasksTabTarget: Hashable {
    /// The To ship group, at the lane that holds the project's tasks when
    /// there is one.
    case toShip(projectID: UUID?)
    case done
}

/// A request to show the Tasks tab at a group. Each request is new, so the
/// same target can be asked for twice.
struct ToasttyTasksScrollRequest: Equatable {
    let target: ToasttyTasksTabTarget
    let id = UUID()
}

extension TaskBucket {
    /// Yellow for Needs you, the review mark's blue for Ready to review;
    /// `nil` for the calm buckets.
    var tint: Color? {
        switch self {
        case .needsYou: ToasttyDesignTokens.needsYou
        case .readyToReview: ToasttyDesignTokens.taskReview
        case .running, .idle: nil
        }
    }
}

/// Home's All segment while the Mac runs its task system: each project as a
/// card with its sessions, task spaces and tasks in the Mac sidebar's
/// buckets, then its To ship line. Emits sibling rows so the List gives
/// each its own cell and its own swipe actions.
struct ToasttyProjectCards: View {
    let cards: [MobileHomeCard]
    let controller: HomeScreenController
    @Binding var spawnerFilter: ToasttySpawnerChip?
    @Binding var infoConversation: ToasttySessionInfoSelection?
    let openWorkspace: (UUID) -> Void
    let openTask: (RemoteTaskSummary) -> Void
    let showTasks: (ToasttyTasksTabTarget) -> Void
    let onSpawnerChip: (ToasttySpawnerChip) -> Void

    @AppStorage(ToasttyCollapsedSubspaceGroups.projectCardsPreferenceKey) private var storedCollapsedCards = ""
    /// Cards whose To ship line shows its tasks; it starts folded, as on
    /// the Mac.
    @State private var expandedToShipCardIDs: Set<UUID> = []

    var body: some View {
        ForEach(cards) { card in
            Group {
                ToasttyProjectCardHeader(
                    card: card,
                    freshness: controller.freshness,
                    isCollapsed: isCollapsed(card),
                    toggleCollapsed: { toggleCollapsed(card) },
                    openWorkspace: openWorkspace
                )
                .padding(.top, 12)
                .toasttyListRow(vertical: 0)
                .id(Self.cardScrollID(card.id))
                if isCollapsed(card) == false {
                    if let filter = spawnerFilter, filter.parentWorkspaceID == card.id {
                        ToasttySpawnerFilterBar(filter: filter, controller: controller) {
                            spawnerFilter = nil
                        }
                        .toasttyListRow()
                    }
                    ForEach(TaskBucket.allCases, id: \.self) { bucket in
                        let entries = card.layout.entries(bucket)
                        if entries.isEmpty == false {
                            ToasttyTaskGroupHeader(title: bucket.title, count: card.counts[bucket] ?? 0, tint: bucket.tint)
                                .padding(.top, 2)
                                .accessibilityIdentifier("toastty-card-bucket-\(card.id.uuidString)-\(bucket)")
                                .toasttyListRow(vertical: 0)
                            ForEach(entries) { entry in
                                row(entry, in: card)
                            }
                        }
                    }
                    toShipLine(card)
                }
            }
        }
    }

    static func cardScrollID(_ id: UUID) -> String {
        "card-\(id.uuidString)"
    }

    private func isCollapsed(_ card: MobileHomeCard) -> Bool {
        card.isOtherTasks == false
            && ToasttyCollapsedSubspaceGroups(storedValue: storedCollapsedCards).contains(card.id)
    }

    private func toggleCollapsed(_ card: MobileHomeCard) {
        var collapsed = ToasttyCollapsedSubspaceGroups(storedValue: storedCollapsedCards)
        collapsed.set(card.id, collapsed: collapsed.contains(card.id) == false)
        storedCollapsedCards = collapsed.storedValue
    }

    @ViewBuilder
    private func row(_ entry: MobileHomeBucketEntry, in card: MobileHomeCard) -> some View {
        switch entry.payload {
        case .conversation(let conversation):
            let chip = ToasttySpawnerChip.chip(for: conversation, in: controller.snapshot, filter: .all)
            ToasttySessionRow(
                conversation: conversation,
                freshness: controller.freshness,
                accessibilityIdentifier: "toastty-mobile-grouped-card-\(conversation.id.uuidString)",
                spawnerChip: chip,
                isSpawnerFilterActive: chip != nil && spawnerFilter?.conversationID == conversation.id,
                onSpawnerChip: onSpawnerChip,
                canFlag: controller.canFlagConversations,
                onFlag: { controller.setConversationFlag(conversation.id, isFlagged: $0) },
                onOpen: controller.open
            )
            .modifier(ToasttyBucketEntryStyle(entry: entry))
            .toasttyListRow()
            .toasttySessionSwipeActions(conversation, controller: controller, infoConversation: $infoConversation)
        case .subspace(let subspace):
            ToasttySubspaceRow(
                row: subspace,
                parentTitle: card.title,
                controller: controller,
                openWorkspace: openWorkspace
            )
            .modifier(ToasttyBucketEntryStyle(entry: entry))
            .toasttyListRow()
            .toasttySubspaceDoneSwipe(subspace, controller: controller)
        case .task(let task):
            ToasttyTaskRow(task: task, freshness: controller.freshness, controller: controller) {
                openTask(task)
            }
            .modifier(ToasttyBucketEntryStyle(entry: entry))
            .toasttyListRow()
        }
    }

    /// "› To ship 2" and "Done 14 ›" under the buckets. The chevron shows
    /// the project's latest To ship tasks in place; the count and Done
    /// switch to the Tasks tab at their group.
    @ViewBuilder
    private func toShipLine(_ card: MobileHomeCard) -> some View {
        let isExpanded = expandedToShipCardIDs.contains(card.id)
        if card.toShipCount > 0 || card.doneCount > 0 {
            HStack(spacing: 4) {
                if card.toShipTasks.isEmpty == false {
                    Button {
                        if isExpanded {
                            expandedToShipCardIDs.remove(card.id)
                        } else {
                            expandedToShipCardIDs.insert(card.id)
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 28, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .accessibilityLabel("\(isExpanded ? "Hide" : "Show") the latest tasks to ship")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("toastty-card-to-ship-toggle-\(card.id.uuidString)")
                }
                if card.toShipCount > 0 {
                    Button {
                        showTasks(.toShip(projectID: card.workspace?.id))
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.square")
                            Text("To ship \(card.toShipCount)")
                        }
                        .foregroundStyle(ToasttyDesignTokens.taskToShip)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("To ship \(card.toShipCount)")
                    .accessibilityHint("Shows the tasks to ship in Tasks")
                    .accessibilityIdentifier("toastty-card-to-ship-\(card.id.uuidString)")
                }
                // Slice 4 puts Release… here.
                Spacer(minLength: 8)
                if card.doneCount > 0 {
                    Button {
                        showTasks(.done)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Done \(card.doneCount)")
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Done \(card.doneCount)")
                    .accessibilityHint("Shows the done tasks in Tasks")
                    .accessibilityIdentifier("toastty-card-done-\(card.id.uuidString)")
                }
            }
            .font(.caption2.monospaced())
            .padding(.leading, card.toShipTasks.isEmpty ? 10 : 2)
            .padding(.trailing, 10)
            .toasttyListRow(vertical: 0)
            if isExpanded {
                ForEach(card.toShipTasks) { task in
                    ToasttyTaskRow(task: task, freshness: controller.freshness, controller: controller) {
                        openTask(task)
                    }
                    .toasttyListRow()
                }
            }
        }
    }
}

extension VerticalAlignment {
    /// The middle of a project card's name line.
    private enum CardName: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
            dimensions[VerticalAlignment.center]
        }
    }

    static let cardName = VerticalAlignment(CardName.self)
}

/// A bucket row under the task that started it, or dimmed because its own
/// state is calmer than its bucket's.
private struct ToasttyBucketEntryStyle: ViewModifier {
    let entry: MobileHomeBucketEntry

    func body(content: Content) -> some View {
        content
            .padding(.leading, entry.isLinkedChild ? 18 : 0)
            .opacity(entry.isContext ? 0.55 : 1)
    }
}

/// A card's name line: the collapse chevron, the project's name, which
/// opens its workspace, and a count for each bucket that has rows.
struct ToasttyProjectCardHeader: View {
    let card: MobileHomeCard
    let freshness: LiveProjectionFreshness
    let isCollapsed: Bool
    let toggleCollapsed: () -> Void
    let openWorkspace: (UUID) -> Void

    var body: some View {
        // The chevron and the counts line up with the name, above any
        // annotation chips.
        HStack(alignment: .cardName, spacing: 2) {
            if card.isOtherTasks == false {
                Button(action: toggleCollapsed) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isCollapsed ? "Expand" : "Collapse") \(card.title)")
                .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
                .accessibilityIdentifier("toastty-card-collapse-\(card.id.uuidString)")
            }
            if let workspace = card.workspace {
                Button {
                    openWorkspace(workspace.id)
                } label: {
                    nameAndCounts(workspace.annotations)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint("Opens the workspace")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("toastty-mobile-workspace-\(workspace.id.uuidString)")
            } else {
                nameAndCounts([])
                    .padding(.leading, 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("toastty-card-other-tasks")
            }
        }
    }

    private func nameAndCounts(_ annotations: [RemoteWorkspaceAnnotation]) -> some View {
        HStack(alignment: .cardName, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(card.isOtherTasks ? .subheadline : .headline)
                    .foregroundStyle(card.isOtherTasks ? ToasttyDesignTokens.secondaryText : ToasttyDesignTokens.primaryText)
                    .lineLimit(1)
                    .frame(minHeight: 30)
                    .alignmentGuide(.cardName) { $0[VerticalAlignment.center] }
                if isCollapsed == false, annotations.isEmpty == false {
                    ToasttyWorkspaceHeaderAnnotations(annotations: annotations)
                        .padding(.top, 3)
                        .padding(.bottom, 2)
                }
            }
            Spacer(minLength: 8)
            ToasttyBucketCounts(counts: card.counts, freshness: freshness)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.trailing, 6)
        .contentShape(Rectangle())
    }

    private var accessibilityLabel: String {
        ([card.title]
            + (card.workspace?.annotations ?? []).map(ToasttyWorkspaceAnnotationAccessibility.label(for:))
            + [ToasttyBucketCounts.label(card.counts)].filter { $0.isEmpty == false })
            .joined(separator: ", ")
    }
}

/// A card's counts by bucket, as on the Mac: a yellow dot for Needs you, a
/// blue square for Ready to review, an arc for Running and a gray dot for
/// Idle. Empty buckets show no count.
struct ToasttyBucketCounts: View {
    let counts: [TaskBucket: Int]
    let freshness: LiveProjectionFreshness

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TaskBucket.allCases, id: \.self) { bucket in
                if let count = counts[bucket], count > 0 {
                    HStack(spacing: 3) {
                        mark(bucket)
                        Text("\(count)")
                            .foregroundStyle(color(bucket))
                    }
                }
            }
        }
        .font(.caption2.monospaced().weight(.semibold))
        .fixedSize()
        .accessibilityHidden(true)
    }

    /// "2 need you, 1 ready for review, 3 running, 2 idle", leaving out
    /// empty buckets.
    static func label(_ counts: [TaskBucket: Int]) -> String {
        TaskBucket.allCases.compactMap { bucket -> String? in
            guard let count = counts[bucket], count > 0 else { return nil }
            return switch bucket {
            case .needsYou: "\(count) \(count == 1 ? "needs" : "need") you"
            case .readyToReview: "\(count) ready for review"
            case .running: "\(count) running"
            case .idle: "\(count) idle"
            }
        }
        .joined(separator: ", ")
    }

    private func color(_ bucket: TaskBucket) -> Color {
        guard freshness == .live else { return ToasttyDesignTokens.mutedText }
        return bucket.tint ?? ToasttyDesignTokens.mutedText
    }

    @ViewBuilder
    private func mark(_ bucket: TaskBucket) -> some View {
        switch bucket {
        case .needsYou:
            Circle().fill(color(bucket)).frame(width: 6, height: 6)
        case .readyToReview:
            RoundedRectangle(cornerRadius: 1.5).fill(color(bucket)).frame(width: 6, height: 6)
        case .running:
            // A still arc: the rows' own spinners already show the motion.
            Circle()
                .trim(from: 0.16, to: 0.9)
                .stroke(ToasttyDesignTokens.mutedText, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .frame(width: 8, height: 8)
        case .idle:
            Circle().fill(ToasttyDesignTokens.offline).frame(width: 6, height: 6)
        }
    }
}

/// Home's switcher while the Mac runs its task system: All, and Needs you
/// with its count in the Needs you yellow. A segmented picker cannot color
/// part of a title, so this draws its own segments.
struct ToasttyHomeSegmentControl: View {
    @Binding var selection: ToasttyHomeSegment
    let needsYouCount: Int

    var body: some View {
        HStack(spacing: 2) {
            segment(.all) {
                Text(ToasttyHomeSegment.all.title)
            }
            segment(.needsYou) {
                HStack(spacing: 5) {
                    Text(ToasttyHomeSegment.needsYou.title)
                    if needsYouCount > 0 {
                        Text("\(needsYouCount)")
                            .foregroundStyle(ToasttyDesignTokens.needsYou)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(2)
        .background(ToasttyDesignTokens.raisedSurface, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).stroke(ToasttyDesignTokens.border)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toastty-mobile-home-segment")
    }

    private func segment<Label: View>(_ value: ToasttyHomeSegment, @ViewBuilder label: () -> Label) -> some View {
        let isSelected = selection == value
        return Button {
            selection = value
        } label: {
            label()
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? ToasttyDesignTokens.primaryText : ToasttyDesignTokens.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7).fill(ToasttyDesignTokens.elevatedSurface)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value == .needsYou && needsYouCount > 0 ? "\(value.title), \(needsYouCount)" : value.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("toastty-mobile-home-segment-\(value.rawValue)")
    }
}
