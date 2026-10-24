import AppKit
import ConversationUI
import CoreState
import RemoteProtocol
import SwiftUI

enum CoordinatorComposer: Hashable { case coordinator, peek }

private struct ConversationBottomPreference: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() }
}

/// Mac composition and scrolling stay platform-specific; message content is shared with iPhone.
struct NativeConversationView<Header: View, Empty: View>: View {
    @ObservedObject var conversation: CoordinatorConversationModel
    let openTerminal: () -> Void
    var focusedComposer: FocusState<CoordinatorComposer?>.Binding
    var pane: CoordinatorComposer
    var composerLabel = "Message"
    var viewportStore: NativeConversationViewportStore?
    var viewportPanelID: UUID?
    @ViewBuilder var header: () -> Header
    @ViewBuilder var empty: () -> Empty
    @State private var confirmsDraftRelease = false
    @State private var confirmedDraftHold: CoordinatorConversationModel.DraftHold?
    @State private var followsTail = true
    @State private var isVisible = false
    @StateObject private var viewportSession = NativeConversationViewportSession()

    var body: some View {
        VStack(spacing: 0) {
            header()
            Divider()
            if let viewportStore, let viewportPanelID {
                ScrollViewReader { proxy in
                    ScrollView {
                        transcript.background {
                            NativeConversationViewportMarker(session: viewportSession, store: viewportStore,
                                panelID: viewportPanelID, conversationID: conversation.snapshot?.summary.conversationID,
                                eventIDs: conversation.events.filter(isTranscriptRow).map(\.eventID),
                                isHistoryLoaded: conversation.snapshot.map {
                                    (conversation.events.last?.sequence ?? 0) >= $0.summary.latestSequence
                                } ?? false,
                                scrollTo: { proxy.scrollTo($0, anchor: .top) })
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !viewportSession.followsTail, conversation.snapshot?.pendingInteractions.isEmpty == false {
                            Button("Agent needs a response ↓") { viewportSession.revealTail() }.padding(12)
                        }
                    }
                }
            } else {
                ScrollViewReader { proxy in
                  GeometryReader { viewport in
                    ScrollView {
                        transcript
                    }
                    .coordinateSpace(name: "conversation-scroll")
                    .defaultScrollAnchor(.bottom)
                    .onPreferenceChange(ConversationBottomPreference.self) { bottom in
                        followsTail = bottom.map { $0 <= viewport.size.height + 32 } ?? false
                    }
                    .onChange(of: conversation.events.last) { _, _ in followTail(proxy) }
                    .onChange(of: conversation.snapshot?.pendingInteractions) { _, _ in followTail(proxy) }
                    .onChange(of: viewport.size) { _, _ in followTail(proxy) }
                    .overlay(alignment: .bottomTrailing) {
                        if !followsTail, conversation.snapshot?.pendingInteractions.isEmpty == false {
                            Button("Agent needs a response ↓") {
                                followsTail = true
                                proxy.scrollTo("conversation-bottom", anchor: .bottom)
                            }.padding(12)
                        }
                    }
                  }
                }
            }
            Divider()
            composer
        }
        .background(ToastyTheme.surfaceBackground)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: conversation.draftHold) { _, _ in
            confirmsDraftRelease = false
            confirmedDraftHold = nil
        }
        .confirmationDialog("Is this terminal draft empty?", isPresented: $confirmsDraftRelease,
                            presenting: confirmedDraftHold) { hold in
            Button("The terminal draft is empty") { conversation.releaseTerminalDraft(expected: hold) }
        } message: { _ in Text("Inspect the terminal first. This action permits chat input without clearing text in the terminal.") }
    }

    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if conversation.historyTruncated {
                Text("Earlier messages are outside this view’s retained history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if conversation.events.isEmpty { empty() }
            ForEach(conversation.events, id: \.eventID) { event in
                eventView(event).textSelection(.enabled)
                    .background {
                        if viewportStore != nil, isTranscriptRow(event) {
                            NativeConversationViewportRow(eventID: event.eventID, session: viewportSession)
                        }
                    }
                    .id(event.eventID)
            }
            ForEach(conversation.snapshot?.pendingInteractions ?? [], id: \.id) { interaction in
                ConversationInteractionCard(interaction: interaction,
                    answerState: conversation.answerStates[interaction.id],
                    copy: .init(providerName: conversation.snapshot?.summary.provider.rawValue.capitalized ?? "Agent",
                        answerElsewhere: nil, respondElsewhere: nil,
                        reconnectToAnswer: "Waiting for the agent session",
                        reconnectToRespond: "Waiting for the agent session",
                        readOnlyMessage: "Respond in the terminal",
                        expiredMessage: "Answer window closed · respond in the terminal",
                        unavailableMessage: "This answer is no longer available · respond in the terminal",
                        shortenedPreviewMessage: "Preview shortened. Check the terminal for the full request.",
                        sentOrigin: "Sent from Toastty", sentOriginIcon: "macwindow",
                        structuredChoiceLabel: "Choose in terminal"),
                    onEdit: { conversation.editAnswer($0, interaction: interaction) },
                    onSubmit: { conversation.answer(interaction) })
            }
            Color.clear.frame(height: 1).id("conversation-bottom")
                .background(GeometryReader { bottom in
                    if viewportStore == nil {
                        Color.clear.preference(key: ConversationBottomPreference.self,
                            value: bottom.frame(in: .named("conversation-scroll")).maxY)
                    }
                })
        }
        .scrollTargetLayout(isEnabled: viewportStore != nil && viewportPanelID != nil)
        .padding(20)
    }

    private func followTail(_ proxy: ScrollViewProxy) {
        guard followsTail else { return }
        Task { @MainActor in
            await Task.yield()
            guard isVisible, followsTail else { return }
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
    }

    private func isTranscriptRow(_ event: ConversationEvent) -> Bool {
        switch event.payload {
        case .userMessage, .assistantMessage, .toolStarted, .toolFinished, .subagentSummary, .sendDeliveryUnconfirmed:
            true
        default:
            false
        }
    }

    @ViewBuilder
    private func eventView(_ event: ConversationEvent) -> some View {
        switch event.payload {
        case .userMessage(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text("Message").font(.caption).foregroundStyle(.secondary)
                ConversationSelectableText(AttributedString(message.text))
            }
        case .assistantMessage(let message): ConversationMarkdownText(text: message.text)
        case .toolStarted(let tool): ConversationToolEventRow(summary: tool.toolName, detail: tool.detail)
        case .toolFinished(let tool): ConversationToolEventRow(summary: tool.toolName ?? "Tool result", detail: tool.detail)
        case .subagentSummary(let summary): ConversationToolEventRow(summary: summary.displayName, detail: summary.detail, systemImage: "person.2")
        case .sendDeliveryUnconfirmed: Text("Message delivery could not be confirmed. Check the terminal.").foregroundStyle(.orange)
        default: EmptyView()
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if conversation.hasDraftFromPreviousSession {
                Text("The session changed. Copy or clear this draft before writing to the current session.")
                    .font(.caption).foregroundStyle(.orange)
                HStack {
                    Button("Copy draft") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(conversation.draft, forType: .string)
                    }
                    Button("Clear draft") { conversation.clearDraftForCurrentSession() }
                }
            }
            if let notice = conversation.notice {
                HStack {
                    Text(notice).font(.caption)
                    Spacer()
                    Button { conversation.notice = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss message")
                }
            }
            if let control = conversation.snapshot?.summary.inputControl {
                if !control.queuedMessages.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(control.queuedMessages, id: \.clientRequestID) { message in
                                HStack {
                                    Text("Queued: \(message.text)").font(.caption).lineLimit(2)
                                    Spacer()
                                    Button("Remove") { conversation.updateQueue(.remove, requestID: message.clientRequestID) }
                                }
                            }
                        }
                    }.frame(maxHeight: 120)
                }
                if control.isQueuePaused { Button("Resume queued messages") { conversation.updateQueue(.resume) } }
            }
            if case .localDraft = conversation.snapshot?.summary.inputAvailability {
                HStack {
                    Text("Input is held by the terminal draft.").font(.caption)
                    Button("Check terminal", action: openTerminal)
                    Button("Release draft hold") {
                        confirmedDraftHold = conversation.draftHold
                        confirmsDraftRelease = confirmedDraftHold != nil
                    }
                }
            }
            ForEach(conversation.attachments) { file in
                HStack {
                    Text(RemoteAttachmentPolicy.displayFilename(file.filename)).font(.caption)
                    Button { conversation.attachments.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel("Remove \(RemoteAttachmentPolicy.displayFilename(file.filename))")
                }
            }
            TextEditor(text: $conversation.draft)
                .font(.body).frame(minHeight: 52, maxHeight: 110)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(composerLabel)
                .focused(focusedComposer, equals: pane)
            HStack {
                Button { chooseAttachments() } label: { Image(systemName: "paperclip") }
                    .accessibilityLabel("Attach files")
                if conversation.snapshot?.summary.inputControl?.canInterrupt == true {
                    Button("Stop") { conversation.interrupt() }
                }
                Spacer()
                if conversation.inputEpoch == nil && conversation.snapshot?.summary.inputControl?.canSteer == true {
                    Button("Send now") { Task { await conversation.send(steer: true) } }.disabled(!conversation.canSteer)
                }
                Button(conversation.inputEpoch == nil ? "Queue message" : "Send") {
                    Task { await conversation.send() }
                }.buttonStyle(.borderedProminent).disabled(!conversation.canSend)
                    .keyboardShortcut(focusedComposer.wrappedValue == pane ? KeyboardShortcut(.return, modifiers: .command) : nil)
            }
        }.padding(14)
    }

    private func chooseAttachments() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK else { return }
        guard picker.urls.count + conversation.attachments.count <= RemoteAttachmentPolicy.maximumCount else {
            conversation.notice = "Attach up to 4 files."
            return
        }
        do {
            var files = conversation.attachments
            var totalBytes = files.reduce(0) { $0 + $1.data.count }
            for url in picker.urls {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                totalBytes += size
                guard size <= RemoteAttachmentPolicy.maximumFileBytes,
                      totalBytes <= RemoteAttachmentPolicy.maximumTotalBytes else {
                    conversation.notice = "Each attachment must be at most 4 MiB, and all attachments must total at most 8 MiB."
                    return
                }
                files.append(.init(filename: url.lastPathComponent, data: try Data(contentsOf: url)))
            }
            if let error = RemoteAttachmentPolicy.validationError(for: files) { conversation.notice = error; return }
            conversation.attachments = files
        } catch { conversation.notice = error.localizedDescription }
    }
}
