import CoreState
import Foundation

extension AppControlActionID {
    var isWebhookAction: Bool {
        switch self {
        case .webhookAdd, .webhookSet, .webhookRemove, .webhookTest: true
        default: false
        }
    }
}

/// `webhook.*`: register, change, test and remove the webhooks that
/// receive task events. Approval happens only in the app's UI, so no
/// command here can make a webhook send.
extension AppControlExecutor {
    func runWebhookAction(_ action: AppControlActionID, args: [String: AutomationJSONValue]) throws -> AppControlActionOutcome {
        let service = try requiredWebhookService()
        let name = try webhookName(args)
        do {
            switch action {
            case .webhookAdd:
                let webhook = try service.add(
                    name: name,
                    settings: try webhookSettings(args),
                    secret: args.webhookString("secret"),
                    requester: webhookRequester()
                )
                return .init(didMutateState: true, result: Self.webhookSnapshot(webhook, service: service))
            case .webhookSet:
                let webhook = try service.update(
                    name: name,
                    settings: try webhookSettings(args),
                    secret: args.webhookString("secret"),
                    requester: webhookRequester()
                )
                return .init(didMutateState: true, result: Self.webhookSnapshot(webhook, service: service))
            case .webhookRemove:
                try service.remove(name: name)
                return .init(didMutateState: true, result: ["name": .string(name), "removed": .bool(true)])
            default:
                throw AutomationSocketError.invalidPayload("\(action.rawValue) sends a request; run it through app_control.run_action")
            }
        } catch let error as TaskWebhookValidationError {
            throw AutomationSocketError.invalidPayload(error.message)
        }
    }

    /// Read inside the request's context, before the send.
    func prepareWebhookTest(args: [String: AutomationJSONValue]) throws -> (TaskWebhookService, String) {
        (try requiredWebhookService(), try webhookName(args))
    }

    func runWebhookTest(service: TaskWebhookService, name: String) async throws -> AppControlActionOutcome {
        do {
            let delivery = try await service.sendTest(name: name)
            var result: [String: AutomationJSONValue] = [
                "name": .string(name),
                "delivered": .bool((200...299).contains(delivery.statusCode ?? 0)),
                "result": .string(delivery.summary),
            ]
            if let statusCode = delivery.statusCode { result["statusCode"] = .int(statusCode) }
            return .init(didMutateState: false, result: result)
        } catch let error as TaskWebhookValidationError {
            throw AutomationSocketError.invalidPayload(error.message)
        }
    }

    func runWebhookList(args: [String: AutomationJSONValue]) throws -> [String: AutomationJSONValue] {
        let service = try requiredWebhookService()
        var webhooks = service.webhooks
        if let name = args.webhookString("name") {
            webhooks = webhooks.filter { $0.name == name }
            guard webhooks.isEmpty == false else { throw AutomationSocketError.invalidPayload("No webhook is named \(name).") }
        }
        return ["webhooks": .array(webhooks.map { .object(Self.webhookSnapshot($0, service: service)) })]
    }

    private func requiredWebhookService() throws -> TaskWebhookService {
        // A workspace-scoped session may not see every task, and a webhook
        // reports on every task, so it may not manage webhooks.
        if let caller = requestContext().callerSessionID, callerIsWorkspaceScoped(sessionID: caller) {
            throw AutomationSocketError.invalidPayload("A workspace-scoped session cannot manage task webhooks.")
        }
        guard let service = taskCoordinator?.webhooks else {
            throw AutomationSocketError.invalidPayload("Task webhooks are not available.")
        }
        return service
    }

    private func webhookName(_ args: [String: AutomationJSONValue]) throws -> String {
        guard let name = args.webhookString("name") else { throw AutomationSocketError.invalidPayload("name is required") }
        return name
    }

    private func webhookSettings(_ args: [String: AutomationJSONValue]) throws -> TaskWebhookService.Settings {
        var settings = TaskWebhookService.Settings()
        settings.url = args.webhookString("url")
        if args["events"] != nil {
            settings.events = try Self.webhookStrings("events", args: args).flatMap { raw in
                try raw.split(separator: ",").map { part -> TaskWebhookEventType in
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    guard let event = TaskWebhookEventType(rawValue: trimmed) else {
                        throw AutomationSocketError.invalidPayload(
                            "\(trimmed) is not an event; use: \(TaskWebhookEventType.allCases.map(\.rawValue).joined(separator: ", "))"
                        )
                    }
                    return event
                }
            }
        }
        if args["roots"] != nil {
            settings.roots = try Self.webhookStrings("roots", args: args)
        }
        if case .string(let prefix)? = args["externalRefPrefix"] {
            settings.externalRefPrefix = .some(prefix.isEmpty ? nil : prefix)
        }
        if let raw = args.webhookString("auth") {
            guard let auth = TaskWebhookAuth(raw) else {
                throw AutomationSocketError.invalidPayload("auth must be bearer, header:<Name>, hmac or none")
            }
            settings.auth = auth
        }
        if case .string(let hint)? = args["secretHint"] {
            settings.secretHint = .some(hint.isEmpty ? nil : hint)
        }
        return settings
    }

    private static func webhookStrings(_ key: String, args: [String: AutomationJSONValue]) throws -> [String] {
        switch args[key] {
        case .string(let value)?:
            return [value]
        case .array(let values)?:
            return try values.map { value in
                guard case .string(let string) = value else { throw AutomationSocketError.invalidPayload("\(key) must be strings") }
                return string
            }
        default:
            throw AutomationSocketError.invalidPayload("\(key) must be a string or a list of strings")
        }
    }

    /// Who asked: the approval sheet warns when it was an agent session.
    private func webhookRequester() -> TaskWebhookRequester {
        guard let session = callerManagedSession() else { return TaskWebhookRequester() }
        let title = taskCoordinator?.task(inWorkspace: session.workspaceID)?.title
        return TaskWebhookRequester(agentTaskTitle: title, agentSessionID: session.sessionID)
    }

    /// Never the secret, and the URL only with its path shortened.
    static func webhookSnapshot(_ webhook: TaskWebhook, service: TaskWebhookService) -> [String: AutomationJSONValue] {
        func date(_ value: Date?) -> AutomationJSONValue {
            value.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
        }
        var snapshot: [String: AutomationJSONValue] = [
            "id": .string(webhook.id.uuidString),
            "name": .string(webhook.name),
            "status": .string(webhook.status.rawValue),
            "active": .bool(service.isActive(webhook)),
            "host": .string(webhook.host),
            "url": .string(webhook.displayURL),
            "events": .array(webhook.events.map { .string($0.rawValue) }),
            "roots": .array(webhook.roots.map(AutomationJSONValue.string)),
            "externalRefPrefix": webhook.externalRefPrefix.map(AutomationJSONValue.string) ?? .null,
            "auth": .string(webhook.auth.description),
            "hasSecret": .bool(service.hasSecret(webhook.id)),
            "secretHint": webhook.secretHint.map(AutomationJSONValue.string) ?? .null,
            "requestedAt": date(webhook.requestedAt),
            "approvedAt": date(webhook.approvedAt),
            "disabledReason": webhook.disabledReason.map(AutomationJSONValue.string) ?? .null,
            "queuedEvents": .int(service.entries.filter { $0.webhookID == webhook.id }.count),
        ]
        if let delivery = webhook.lastDelivery {
            var object: [String: AutomationJSONValue] = ["at": date(delivery.at), "result": .string(delivery.summary)]
            if let statusCode = delivery.statusCode { object["statusCode"] = .int(statusCode) }
            snapshot["lastDelivery"] = .object(object)
        } else {
            snapshot["lastDelivery"] = .null
        }
        return snapshot
    }
}

private extension Dictionary where Key == String, Value == AutomationJSONValue {
    func webhookString(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }
}
