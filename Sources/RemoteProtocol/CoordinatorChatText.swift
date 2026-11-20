import Foundation

extension CoordinatorTaskLink {
    /// The task as a one-line Markdown link, `[title](toastty://task/<id>)`:
    /// the form the coordinator writes and the form a mention in the user's
    /// message takes. The title is escaped as a digest escapes it.
    public static func markdown(taskID: UUID, title: String) -> String {
        "[\(linkText(title))](\(url(taskID: taskID).absoluteString))"
    }
}

/// Folds a digest that Toastty typed into one line of the chat.
public enum CoordinatorDigestFold {
    /// The number of updates a digest lists, or `nil` when the text is not
    /// one of Toastty's digests.
    public static func updateCount(inMessage text: String) -> Int? {
        guard text.hasPrefix(CoordinatorMessageHeader.digestPrefix) else { return nil }
        return text.split(whereSeparator: \.isNewline).dropFirst().filter { $0.hasPrefix("- ") }.count
    }

    /// The one line the chat shows for a digest: "Toastty · 2 updates · 14:05".
    public static func summary(updateCount: Int, time: String) -> String {
        "\(title(updateCount: updateCount)) · \(time)"
    }

    /// The line without its time: "Toastty · 2 updates". While the turn
    /// that the digest started runs, the line shows the turn's running
    /// time in place of the time.
    public static func title(updateCount: Int) -> String {
        updateCount == 1 ? "Toastty · 1 update" : "Toastty · \(updateCount) updates"
    }

    /// The one line for several quiet wake turns in a row:
    /// "Toastty · 3 quiet checks · 1:40 – 2:01 PM". `timeRange` runs from
    /// the first check's digest to the last one's.
    public static func quietChecksSummary(count: Int, timeRange: String) -> String {
        "Toastty · \(count) quiet checks · \(timeRange)"
    }
}
