import Foundation

/// A link from the coordinator's text to one task: `toastty://task/<id>`.
///
/// The coordinator's text is an agent's text, so it is not trusted. Only
/// this exact form names a task. Every other `toastty:` URL names nothing,
/// and the chat shows it as plain text that a click cannot open.
public enum CoordinatorTaskLink {
    public static let scheme = "toastty"

    /// Whether the URL uses the `toastty:` scheme at all. The chat never
    /// hands such a URL to the system, whatever it says.
    public static func isToasttyURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// The task the URL names, or `nil` when the URL is not exactly
    /// `toastty://task/<id>` with a full task ID. A user, password, port,
    /// query, fragment or further path makes it `nil`.
    public static func taskID(in url: URL) -> UUID? {
        guard isToasttyURL(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == "task",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else { return nil }
        // The raw path, so an encoded separator cannot pass as part of an ID.
        let path = components.percentEncodedPath
        guard path.hasPrefix("/") else { return nil }
        let idText = String(path.dropFirst())
        // `UUID(uuidString:)` takes only the 36 character form.
        guard idText.count == 36, let id = UUID(uuidString: idText) else { return nil }
        return id
    }

    public static func url(taskID: UUID) -> URL {
        URL(string: "\(scheme)://task/\(taskID.uuidString)")!
    }
}
