import Observation
import SwiftUI
import UIKit

/// Receives content from the share sheet, saves it in the App Group, and
/// opens Toastty's new-session sheet with it.
final class ToasttyShareViewController: UIViewController {
    private let status = ToasttyShareStatus()
    private var handoff: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ToasttyShareView(status: status) { [weak self] in
            self?.close()
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The app is reached through the responder chain, which ends at the
        // application only once this view is in a window.
        guard handoff == nil else { return }
        handoff = Task { await handOff() }
    }

    private func handOff() async {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let store = ToasttySharedDraftStore(appGroupID: info["ToasttyMobileAppGroup"] as? String),
              let scheme = info["ToasttyMobileURLScheme"] as? String, scheme.isEmpty == false else {
            status.phase = .failed("This copy of Toastty can't receive shared items.")
            return
        }
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let draft = await ToasttyShareImporter.makeDraft(from: items)
        // Cancel closed the extension while the items loaded.
        guard Task.isCancelled == false else { return }
        guard draft.isEmpty == false else {
            status.phase = .failed("Toastty can't use this. Share images, PDFs, text files, text, or a link.")
            return
        }
        do {
            // Marked before the link: the app finds the draft later if the
            // link does not open it, such as before the phone is paired.
            try store.save(draft)
            try store.markWaiting(id: draft.id)
        } catch {
            status.phase = .failed("Toastty couldn't save what you shared. Try again.")
            return
        }
        if let url = URL(string: "\(scheme)://new-session/\(draft.id.uuidString)"), await openApp(url) {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            status.phase = .saved
        }
    }

    /// Extensions have no supported API to open their app. The application
    /// object at the end of the responder chain still opens a URL.
    private func openApp(_ url: URL) async -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                return await application.open(url, options: [:])
            }
            responder = current.next
        }
        return false
    }

    private func close() {
        handoff?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@MainActor
@Observable
final class ToasttyShareStatus {
    enum Phase: Equatable {
        case preparing
        /// Saved, but the app did not open.
        case saved
        case failed(String)
    }

    var phase: Phase = .preparing
}

private struct ToasttyShareView: View {
    let status: ToasttyShareStatus
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch status.phase {
            case .preparing:
                ProgressView()
                Text("Preparing for Toastty…")
                    .font(.headline)
            case .saved:
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("Saved for a new session")
                    .font(.headline)
                Text("Open Toastty within 30 minutes to start it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
            Button(status.phase == .preparing ? "Cancel" : "Done", action: close)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("toastty-share-close")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toastty-share-status")
    }
}
