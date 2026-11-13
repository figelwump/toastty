import Foundation

/// Folds a digest that Toastty typed into one line of the chat.
public enum CoordinatorDigestFold {
    /// The number of updates a digest lists, or `nil` when the text is not
    /// one of Toastty's digests.
    public static func updateCount(inMessage text: String) -> Int? {
        guard text.hasPrefix(CoordinatorWakeState.digestPrefix) else { return nil }
        return text.split(whereSeparator: \.isNewline).dropFirst().filter { $0.hasPrefix("- ") }.count
    }

    /// The one line the chat shows for a digest: "Toastty · 2 updates · 14:05".
    public static func summary(updateCount: Int, time: String) -> String {
        let updates = updateCount == 1 ? "1 update" : "\(updateCount) updates"
        return "Toastty · \(updates) · \(time)"
    }
}
