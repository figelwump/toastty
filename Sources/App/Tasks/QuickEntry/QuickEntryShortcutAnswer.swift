import CoreState
import Foundation

/// Whether Toastty may take the default quick entry shortcut in every app
/// when `tasks.toml` does not set one.
enum QuickEntryShortcutPermission: Equatable {
    case allowed
    /// The user cleared "Use ⌥⇧T in every app" in the What's new sheet.
    case declined
    /// The What's new sheet still waits for its answer.
    case waiting
}

/// The user's answer to "Use ⌥⇧T in every app" in the What's new sheet. A
/// global hot key takes the keys from every app, Toastty's own terminals
/// too, so Toastty asks before it takes the default.
enum QuickEntryShortcutAnswer {
    static let key = "toastty.quickEntry.defaultShortcutAllowed"

    static func saved(in defaults: UserDefaults?) -> Bool? {
        guard let defaults, defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    static func save(_ allowed: Bool, in defaults: UserDefaults?) {
        defaults?.set(allowed, forKey: key)
    }

    /// With no saved answer, the default waits only while the sheet still
    /// has the question to ask. A user who will not see the sheet, such as
    /// one who answered the earlier coordinator question, keeps the default.
    static func permission(saved: Bool?, questionWaits: Bool) -> QuickEntryShortcutPermission {
        if let saved { return saved ? .allowed : .declined }
        return questionWaits ? .waiting : .allowed
    }
}

extension QuickEntryShortcutAnswer {
    /// Makes the quick entry key wait for the What's new sheet. With no
    /// saved answer there is no key while the sheet still has its question,
    /// and the key is read again each time the question stops showing.
    /// The message that says why the key is not set up as the user chose
    /// (a `tasks.toml` that cannot be read, a shortcut that is not valid,
    /// or a registration that the system refuses) waits in the controller's
    /// `launchMessage` while the question waits, and `presentMessage` shows
    /// it, as at launch, when the question ends. So the user sees it once.
    /// Carbon does not refuse a key that another app also registered, so
    /// Toastty cannot tell that case.
    @MainActor
    static func connect(
        _ quickEntry: QuickEntryController,
        to offer: CoordinatorStartOffer?,
        defaults: UserDefaults?,
        presentMessage: @escaping @MainActor () -> Void
    ) {
        quickEntry.defaultShortcutPermission = { [weak offer] in
            permission(saved: saved(in: defaults), questionWaits: offer?.shouldOffer ?? false)
        }
        quickEntry.launchMessageWaits = { [weak offer] in
            offer?.shouldOffer ?? false
        }
        offer?.questionEnded = { [weak quickEntry] in
            quickEntry?.loadShortcutAtLaunch()
            // Not from inside the store update that can end the question,
            // and after the sheet has left its window.
            Task { @MainActor in presentMessage() }
        }
    }
}
