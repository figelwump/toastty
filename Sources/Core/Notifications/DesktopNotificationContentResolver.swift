import Foundation

public struct DesktopNotificationContext: Equatable, Sendable {
    public var workspaceTitle: String?
    public var panelLabel: String?

    public init(workspaceTitle: String? = nil, panelLabel: String? = nil) {
        self.workspaceTitle = workspaceTitle
        self.panelLabel = panelLabel
    }
}

public struct DesktopNotificationContent: Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public enum DesktopNotificationContentResolver {
    public static func resolve(
        title: String,
        body: String,
        context: DesktopNotificationContext = DesktopNotificationContext()
    ) -> DesktopNotificationContent {
        let normalizedTitle = normalizedNonEmpty(title)
        let normalizedBody = normalizedNonEmpty(body)
        let workspaceTitle = normalizedNonEmpty(context.workspaceTitle)
        let panelLabel = normalizedNonEmpty(context.panelLabel)

        let fallbackTitle = panelLabel ?? workspaceTitle ?? "Toastty"
        let fallbackBody = contextFallbackBody(workspaceTitle: workspaceTitle, panelLabel: panelLabel)

        let finalTitle = normalizedTitle ?? fallbackTitle
        let finalBody: String
        if let normalizedBody {
            finalBody = normalizedBody
        } else if let fallbackBody {
            finalBody = fallbackBody
        } else if normalizedTitle != nil {
            finalBody = "Open Toastty for details."
        } else {
            finalBody = "Notification"
        }

        return DesktopNotificationContent(title: finalTitle, body: finalBody)
    }

    private static func contextFallbackBody(workspaceTitle: String?, panelLabel: String?) -> String? {
        if let workspaceTitle, let panelLabel {
            guard workspaceTitle.caseInsensitiveCompare(panelLabel) != .orderedSame else {
                return workspaceTitle
            }
            return "\(workspaceTitle) · \(panelLabel)"
        }
        if let panelLabel {
            return panelLabel
        }
        if let workspaceTitle {
            return workspaceTitle
        }
        return nil
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
