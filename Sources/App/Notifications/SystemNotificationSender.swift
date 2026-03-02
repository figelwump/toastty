import CoreState
import Foundation
import UserNotifications

/// Delivers macOS user notifications via UNUserNotificationCenter.
///
/// Permission is requested lazily on the first send attempt. Subsequent
/// calls skip the authorization request.
///
/// For ad-hoc signed local development builds, UNUserNotificationCenter may
/// reject delivery with `.notificationsNotAllowed`. In that case we fall back
/// to `osascript` so desktop alerts still surface while iterating locally.
@MainActor
enum SystemNotificationSender {
    private static var hasRequestedPermission = false
    private static var userExplicitlyDeniedPermission = false
    private static var useAppleScriptFallback = false

    static func send(title: String, body: String, workspaceID: UUID, panelID: UUID?) async {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = normalizedTitle.isEmpty ? "Toastty" : normalizedTitle
        let finalBody = normalizedBody.isEmpty ? "Notification" : normalizedBody

        if useAppleScriptFallback {
            await sendViaAppleScript(
                title: finalTitle,
                body: finalBody,
                workspaceID: workspaceID,
                panelID: panelID
            )
            return
        }

        await requestPermissionIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = finalTitle
        content.body = finalBody
        content.sound = .default

        // Attach workspace/panel identifiers so a future delegate can route
        // click-to-focus actions (not yet implemented).
        var userInfo: [String: String] = ["workspaceID": workspaceID.uuidString]
        if let panelID {
            userInfo["panelID"] = panelID.uuidString
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            ToasttyLog.debug(
                "Delivered system notification",
                category: .notifications,
                metadata: [
                    "title": finalTitle,
                    "workspace_id": workspaceID.uuidString,
                ]
            )
        } catch {
            if shouldUseAppleScriptFallback(for: error) {
                useAppleScriptFallback = true
            }
            ToasttyLog.warning(
                "Failed to deliver system notification",
                category: .notifications,
                metadata: ["error": error.localizedDescription]
            )
            await sendViaAppleScript(
                title: finalTitle,
                body: finalBody,
                workspaceID: workspaceID,
                panelID: panelID
            )
        }
    }

    private static func requestPermissionIfNeeded() async {
        guard hasRequestedPermission == false else { return }
        hasRequestedPermission = true

        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            userExplicitlyDeniedPermission = !granted
            ToasttyLog.info(
                "Notification permission result",
                category: .notifications,
                metadata: ["granted": granted ? "true" : "false"]
            )
        } catch {
            if shouldUseAppleScriptFallback(for: error) {
                useAppleScriptFallback = true
            }
            ToasttyLog.warning(
                "Notification permission request failed",
                category: .notifications,
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private static func shouldUseAppleScriptFallback(for error: Error) -> Bool {
        guard userExplicitlyDeniedPermission == false else {
            return false
        }
        guard let notificationError = error as? UNError else {
            return false
        }
        return notificationError.code == .notificationsNotAllowed
    }

    private static func sendViaAppleScript(
        title: String,
        body: String,
        workspaceID: UUID,
        panelID: UUID?
    ) async {
        do {
            try await runAppleScriptNotification(title: title, body: body)
            var metadata: [String: String] = [
                "title": title,
                "workspace_id": workspaceID.uuidString,
            ]
            if let panelID {
                metadata["panel_id"] = panelID.uuidString
            }
            ToasttyLog.info(
                "Delivered system notification via AppleScript fallback",
                category: .notifications,
                metadata: metadata
            )
        } catch {
            ToasttyLog.warning(
                "Failed AppleScript notification fallback",
                category: .notifications,
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private static func runAppleScriptNotification(title: String, body: String) async throws {
        let escapedTitle = escapedAppleScriptString(title)
        let escapedBody = escapedAppleScriptString(body)
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
                throw AppleScriptNotificationError.commandFailed(
                    terminationStatus: Int(process.terminationStatus),
                    stderr: stderr
                )
            }
        }.value
    }

    private static func escapedAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

private enum AppleScriptNotificationError: LocalizedError {
    case commandFailed(terminationStatus: Int, stderr: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let terminationStatus, let stderr):
            return "osascript failed with status \(terminationStatus): \(stderr)"
        }
    }
}
