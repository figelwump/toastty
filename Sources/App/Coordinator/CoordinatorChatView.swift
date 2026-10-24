import CoreState
import SwiftUI

struct CoordinatorChatView: View {
    @ObservedObject var session: CoordinatorSessionController
    @ObservedObject var conversation: CoordinatorConversationModel
    let openTerminal: () -> Void
    var focusedComposer: FocusState<CoordinatorComposer?>.Binding
    @State private var showsSettings = false

    var body: some View {
        NativeConversationView(conversation: conversation, openTerminal: openTerminal,
                               focusedComposer: focusedComposer, pane: .coordinator,
                               composerLabel: "Message Coordinator") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Coordinator").font(.headline)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(statusText).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if session.status != .running && session.status != .starting && session.status != .waitingForRestore {
                        Button("Start") { Task { await session.start() } }
                            .accessibilityLabel("Start Coordinator")
                    }
                    Button("Terminal", action: openTerminal).disabled(session.identity == nil)
                    Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Coordinator settings")
                }
                if case .error(let message) = session.status {
                    Text(message).font(.caption).foregroundStyle(.orange)
                } else if case .unavailable(let message) = session.status {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16)
        } empty: {
            emptyState
        }
        .sheet(isPresented: $showsSettings) { CoordinatorSettingsView(session: session) }
    }

    private var statusText: String {
        switch session.status {
        case .unavailable: "Unavailable"
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .waitingForRestore: "Resuming"
        case .running: conversation.snapshot?.summary.statusDetail ?? "Connected"
        case .error: "Needs attention"
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make the next decision with the evidence in view.").font(.title3)
            Text("The Coordinator can prepare review briefs and help inspect tasks. Your review queue and New Task work independently.")
                .foregroundStyle(.secondary)
            if session.status != .running && session.status != .starting && session.status != .waitingForRestore {
                Button("Start Coordinator") { Task { await session.start() } }
                    .buttonStyle(.borderedProminent)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
    }

}

private struct CoordinatorSettingsView: View {
    @ObservedObject var session: CoordinatorSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var profileID = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var automatic = true
    @State private var error: String?

    var body: some View {
        Form {
            Text("Coordinator settings").font(.headline)
            Picker("Agent", selection: $profileID) {
                ForEach(session.availableProfiles, id: \.profileID) { profile in
                    Text(profile.displayName).tag(profile.profileID)
                }
            }
            TextField("Model (agent default if empty)", text: $model)
            TextField("Reasoning effort (agent default if empty)", text: $effort)
            Toggle("Prepare reviews automatically", isOn: $automatic)
            Text("Agent settings apply to the next session. Pausing automatic work does not stop a running turn.").font(.caption)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save") { save() } }
        }.padding(24).frame(width: 440)
        .onAppear {
            profileID = session.configuration.profileID ?? ""
            model = session.configuration.model ?? ""
            effort = session.configuration.reasoningEffort ?? ""
            automatic = session.automaticWorkEnabled
        }
    }

    private func save() {
        do {
            try session.configure(profileID: profileID, model: model.isEmpty ? nil : model,
                                  reasoningEffort: effort.isEmpty ? nil : effort)
            try session.setAutomaticWorkEnabled(automatic)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
