import Foundation
import RemoteProtocol
import SwiftUI

// MARK: - What the host does with a click

/// What the chat's host does with the user's clicks on offer cards. The
/// actions are not compared: they are the same for the life of one chat.
public struct ToasttyOfferActions: Sendable {
    /// Sends the answers as the user's message. `offeredAt` is when the
    /// coordinator wrote the message with the offers. False when nothing
    /// was sent; the cards then keep the choices.
    public var send: @MainActor ([CoordinatorOfferAnswer], _ offeredAt: Date) -> Bool
    /// The user asks about one offer: the chat's field then answers it.
    public var ask: @MainActor (CoordinatorOffer, _ offeredAt: Date) -> Void

    public init(
        send: @escaping @MainActor ([CoordinatorOfferAnswer], _ offeredAt: Date) -> Bool,
        ask: @escaping @MainActor (CoordinatorOffer, _ offeredAt: Date) -> Void
    ) {
        self.send = send
        self.ask = ask
    }
}

/// A chat that answers offers: it draws a `toastty-offers` block of an
/// agent's message as cards. Without it, the block shows as its text.
public struct ToasttyOfferCards: Equatable, Sendable {
    public var answers: ToasttyOfferAnswers
    public var actions: ToasttyOfferActions

    public init(answers: ToasttyOfferAnswers, actions: ToasttyOfferActions) {
        self.answers = answers
        self.actions = actions
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.answers == rhs.answers
    }
}

extension EnvironmentValues {
    /// `nil`, the default, draws no offer cards. Only the cards read it:
    /// it changes with each answer.
    @Entry var toasttyOfferCards: ToasttyOfferCards?
    /// The chat draws offer cards. It stays the same for the life of a
    /// chat, so the text of every message can read it.
    @Entry var toasttyDrawsOfferCards = false
    /// Set on the text of an agent's own message. A block of offers in any
    /// other text, such as a sender's card, stays text.
    @Entry var toasttyOfferRow: ToasttyOfferRow?
}

// MARK: - The cards

/// The offers of one message as a group of cards. Each card opens to what
/// the offer is, and takes Yes, Skip or a question. The answers collect,
/// and one button sends them as one message.
struct ToasttyOfferGroupView: View {
    let group: CoordinatorOfferGroup
    @Environment(\.toasttyOfferCards) private var cards
    @Environment(\.toasttyOfferRow) private var row
    @Environment(ToasttyOfferSelections.self) private var sharedSelections: ToasttyOfferSelections?
    @State private var ownSelections = ToasttyOfferSelections()

    private var selections: ToasttyOfferSelections { sharedSelections ?? ownSelections }

    var body: some View {
        if let cards, let row {
            content(cards: cards, row: row)
        }
    }

    private func content(cards: ToasttyOfferCards, row: ToasttyOfferRow) -> some View {
        let layout = ToasttyOfferGroupLayout(group)
        let takesAnswers = cards.answers.takesAnswers(at: row.rowID.sequence)
        let showsMore = selections.groupsShowingMore.contains(row.rowID)
        let showsSkips = selections.groupsShowingSkips.contains(row.rowID)
        return VStack(alignment: .leading, spacing: 0) {
            header(layout: layout, takesAnswers: takesAnswers)
            ForEach(layout.shown) { offer in
                separator
                card(offer, cards: cards, row: row, takesAnswers: takesAnswers)
            }
            if layout.more.isEmpty == false {
                separator
                foldLine(
                    text: "\(layout.more.count) more that I suggest: \(titles(layout.more))",
                    isOpen: showsMore,
                    key: "more",
                    toggle: { toggleMore(row.rowID) }
                ) { EmptyView() }
                if showsMore {
                    ForEach(layout.more) { offer in
                        separator
                        card(offer, cards: cards, row: row, takesAnswers: takesAnswers)
                    }
                }
            }
            if layout.skips.isEmpty == false {
                separator
                foldLine(
                    text: "\(layout.skips.count) that I would skip: \(titles(layout.skips))",
                    isOpen: showsSkips,
                    key: "skips",
                    toggle: { toggleSkips(row.rowID) }
                ) {
                    if takesAnswers {
                        skipAllButton(layout.skips, cards: cards, row: row)
                    }
                }
                if showsSkips {
                    ForEach(layout.skips) { offer in
                        separator
                        card(offer, cards: cards, row: row, takesAnswers: takesAnswers)
                    }
                }
            }
            separator
            footer(cards: cards, row: row, takesAnswers: takesAnswers)
        }
        .background(ConversationDesignTokens.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: ConversationDesignTokens.controlCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ConversationDesignTokens.controlCornerRadius, style: .continuous)
                .stroke(ConversationDesignTokens.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toastty-offers-\(row.rowID.accessibilitySuffix)")
    }

    private var separator: some View {
        Divider().overlay(ConversationDesignTokens.border)
    }

    private func titles(_ offers: [CoordinatorOffer]) -> String {
        offers.map(\.plainTitle).joined(separator: "; ")
    }

    private func toggleMore(_ rowID: ToasttyTranscriptRowID) {
        if selections.groupsShowingMore.remove(rowID) == nil { selections.groupsShowingMore.insert(rowID) }
    }

    private func toggleSkips(_ rowID: ToasttyTranscriptRowID) {
        if selections.groupsShowingSkips.remove(rowID) == nil { selections.groupsShowingSkips.insert(rowID) }
    }

    // MARK: Header and footer

    private func header(layout: ToasttyOfferGroupLayout, takesAnswers: Bool) -> some View {
        let suggested = layout.shown.count + layout.more.count
        var parts: [String] = []
        if suggested > 0 { parts.append("\(suggested) that I suggest") }
        if layout.skips.isEmpty == false { parts.append("\(layout.skips.count) that I would skip") }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Offers · \(group.offers.count)")
                .fontWeight(.semibold)
                .foregroundStyle(ConversationDesignTokens.primaryText)
            Spacer(minLength: 8)
            Text(takesAnswers ? parts.joined(separator: ", ") : "an earlier list")
                .foregroundStyle(ConversationDesignTokens.mutedText)
                .multilineTextAlignment(.trailing)
        }
        .conversationFont(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConversationDesignTokens.codeHeaderSurface)
    }

    private func footer(cards: ToasttyOfferCards, row: ToasttyOfferRow, takesAnswers: Bool) -> some View {
        let pending = selections.pendingAnswers(for: group, in: row, answers: cards.answers)
        let answered = group.offers.filter { cards.answers.choice(for: $0.id, offeredAt: row.rowID.sequence) != nil }.count
        return HStack(alignment: .center, spacing: 10) {
            Text(ToasttyOfferGroupPresentation.footerText(
                takesAnswers: takesAnswers, pending: pending.count, answered: answered, total: group.offers.count
            ))
            .conversationFont(.caption)
            .foregroundStyle(ConversationDesignTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("toastty-offers-count")
            Spacer(minLength: 8)
            if takesAnswers {
                Button("Send answers") {
                    if cards.actions.send(pending, row.timestamp) {
                        selections.didSend(pending, in: row)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(ConversationDesignTokens.amber)
                .conversationFont(.caption, weight: .semibold)
                .disabled(pending.isEmpty)
                .accessibilityIdentifier("toastty-offers-send")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConversationDesignTokens.codeHeaderSurface)
    }

    // MARK: Folded offers

    private func foldLine<Trailing: View>(
        text: String,
        isOpen: Bool,
        key: String,
        toggle: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .conversationFont(size: 9, weight: .semibold)
                    Text(text)
                        .lineLimit(isOpen ? 1 : 2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .conversationFont(.caption)
                .foregroundStyle(ConversationDesignTokens.mutedText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("toastty-offers-show-\(key)")
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Chooses Skip for each offer of the line that has no answer. A second
    /// click takes those choices back.
    private func skipAllButton(_ offers: [CoordinatorOffer], cards: ToasttyOfferCards, row: ToasttyOfferRow) -> some View {
        let open = selections.unanswered(offers, in: row, answers: cards.answers)
        return ToasttyOfferChoiceButton(
            title: open.count == offers.count ? "Skip all \(offers.count)" : "Skip the other \(open.count)",
            isSelected: selections.allSkipped(offers, in: row, answers: cards.answers),
            isSuggested: true
        ) {
            selections.toggleSkipAll(offers, in: row, answers: cards.answers)
        }
        .opacity(open.isEmpty ? 0 : 1)
        .disabled(open.isEmpty)
        .accessibilityIdentifier("toastty-offers-skip-all")
    }

    // MARK: One offer

    private func card(
        _ offer: CoordinatorOffer,
        cards: ToasttyOfferCards,
        row: ToasttyOfferRow,
        takesAnswers: Bool
    ) -> some View {
        let key = ToasttyOfferSelections.Key(rowID: row.rowID, offerID: offer.id)
        return ToasttyOfferCard(
            offer: offer,
            isOpen: selections.openOffers.contains(key),
            sent: cards.answers.choice(for: offer.id, offeredAt: row.rowID.sequence),
            chosen: selections.choices[key],
            takesAnswers: takesAnswers,
            toggleOpen: {
                if selections.openOffers.remove(key) == nil { selections.openOffers.insert(key) }
            },
            choose: { selections.choose($0, for: key) },
            ask: { cards.actions.ask(offer, row.timestamp) }
        )
    }
}

/// One offer: a line that opens to its details, then its answer.
private struct ToasttyOfferCard: View {
    let offer: CoordinatorOffer
    let isOpen: Bool
    /// The answer that the user sent.
    let sent: CoordinatorOfferAnswer.Choice?
    /// The answer that the user chose and did not send yet.
    let chosen: CoordinatorOfferAnswer.Choice?
    let takesAnswers: Bool
    let toggleOpen: () -> Void
    let choose: (CoordinatorOfferAnswer.Choice) -> Void
    let ask: () -> Void

    /// The details and the answer start under the title.
    private static let indent: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggleOpen) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .conversationFont(size: 9, weight: .semibold)
                        .foregroundStyle(ConversationDesignTokens.mutedText)
                        .frame(width: 8)
                    if let kind = offer.kind {
                        Text(kind.uppercased())
                            .conversationFont(.caption2, weight: .semibold)
                            .foregroundStyle(ConversationDesignTokens.mutedText)
                    }
                    Text(Self.inlineMarkdown(offer.title))
                        .conversationFont(.subheadline)
                        .foregroundStyle(ConversationDesignTokens.primaryText)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let listText = offer.listText {
                        Text(listText)
                            .conversationFont(.caption2)
                            .foregroundStyle(
                                offer.isOnLastList ? ConversationDesignTokens.amberText : ConversationDesignTokens.mutedText
                            )
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(offer.plainTitle)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityHint(isOpen ? "Hides what the offer is" : "Shows what the offer is")
            .accessibilityIdentifier("toastty-offer-\(offer.id)-toggle")

            if isOpen {
                details
                    .padding(.leading, Self.indent)
            }
            answer
                .padding(.leading, Self.indent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toastty-offer-\(offer.id)")
    }

    @ViewBuilder
    private var details: some View {
        let details = offer.details
        if details.isEmpty {
            Text("The coordinator gave no details. Ask it about this offer.")
                .conversationFont(.caption)
                .foregroundStyle(ConversationDesignTokens.mutedText)
        } else {
            #if os(macOS)
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(details, id: \.label) { detail in
                    GridRow {
                        detailLabel(detail.label)
                            .gridColumnAlignment(.leading)
                        detailText(detail.text)
                    }
                }
            }
            #else
            VStack(alignment: .leading, spacing: 8) {
                ForEach(details, id: \.label) { detail in
                    VStack(alignment: .leading, spacing: 2) {
                        detailLabel(detail.label)
                        detailText(detail.text)
                    }
                }
            }
            #endif
        }
    }

    private func detailLabel(_ label: String) -> some View {
        Text(label)
            .conversationFont(.caption)
            .foregroundStyle(ConversationDesignTokens.mutedText)
            .fixedSize()
    }

    /// The coordinator's text, with its links and task chips.
    private func detailText(_ text: String) -> some View {
        ToasttyMarkdownText(text: text, textColor: ConversationDesignTokens.secondaryText)
            // A block of offers inside an offer stays text.
            .environment(\.toasttyOfferRow, nil)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var answer: some View {
        if let sent {
            let text = sent == .yes ? "You said yes" : "You skipped it"
            Label(text, systemImage: sent == .yes ? "checkmark" : "minus")
                .conversationFont(.caption, weight: .semibold)
                .foregroundStyle(sent == .yes ? ConversationDesignTokens.green : ConversationDesignTokens.mutedText)
                // One element: iOS reads the icons as "Selected" and "Remove".
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
                .accessibilityIdentifier("toastty-offer-\(offer.id)-answered")
        } else if takesAnswers {
            HStack(spacing: 6) {
                ToasttyOfferChoiceButton(
                    title: "Yes", isSelected: chosen == .yes, isSuggested: offer.suggestion == .yes
                ) { choose(.yes) }
                    .accessibilityIdentifier("toastty-offer-\(offer.id)-yes")
                ToasttyOfferChoiceButton(
                    title: "Skip", isSelected: chosen == .skip, isSuggested: offer.suggestion == .skip
                ) { choose(.skip) }
                    .accessibilityIdentifier("toastty-offer-\(offer.id)-skip")
                Button(action: ask) {
                    Text("Ask…")
                        .conversationFont(.caption)
                        .foregroundStyle(ConversationDesignTokens.mutedText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Ask the coordinator about this offer")
                .accessibilityLabel("Ask about this offer")
                .accessibilityIdentifier("toastty-offer-\(offer.id)-ask")
            }
        }
    }

    /// The title's inline Markdown, such as a code span, without links: the
    /// title is the card's button.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        guard var attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        ) else { return AttributedString(text) }
        for run in attributed.runs {
            if run.link != nil { attributed[run.range].link = nil }
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].foregroundColor = ConversationDesignTokens.amberText
            }
        }
        return attributed
    }
}

/// Yes or Skip on a card. The coordinator's suggestion has the accent's
/// outline, and the user's choice is filled.
private struct ToasttyOfferChoiceButton: View {
    let title: String
    let isSelected: Bool
    let isSuggested: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .conversationFont(.caption, weight: isSuggested || isSelected ? .semibold : .regular)
                .foregroundStyle(foreground)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(isSelected ? ConversationDesignTokens.amber : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(border, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var foreground: Color {
        if isSelected { return ConversationDesignTokens.inkOnAmber }
        return isSuggested ? ConversationDesignTokens.amberText : ConversationDesignTokens.primaryText
    }

    private var border: Color {
        if isSelected { return ConversationDesignTokens.amber }
        return isSuggested ? ConversationDesignTokens.amberText.opacity(0.7) : ConversationDesignTokens.chipBorder
    }
}
