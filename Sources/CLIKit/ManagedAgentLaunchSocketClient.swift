import CoreState
import Foundation

enum ManagedAgentLaunchSocketClient {
    private static let commandName = "agent.prepare_managed_launch"
    private static let preflightDecisionCommandName = "agent.managed_launch_preflight_decision"

    static func prepareManagedLaunch(
        _ request: ManagedAgentLaunchRequest,
        socketPath: String
    ) throws -> ManagedAgentLaunchPreparation {
        let response = try ToasttySocketClient(socketPath: socketPath).send(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: commandName,
                payload: payload(for: request)
            )
        )

        guard response.ok else {
            if let error = response.error {
                throw ToasttyCLIError.runtime("\(error.code): \(error.message)")
            }
            throw ToasttyCLIError.runtime("request failed")
        }

        guard let result = response.result else {
            throw ToasttyCLIError.runtime("request succeeded without a result")
        }

        let data = try JSONEncoder().encode(result)
        do {
            if let kind = result.string("kind"),
               kind == ManagedAgentLaunchPreparationKind.preflightRequired.rawValue {
                return try JSONDecoder().decode(ManagedAgentLaunchPreparation.self, from: data)
            }
            return try ManagedAgentLaunchPreparation(
                plan: JSONDecoder().decode(ManagedAgentLaunchPlan.self, from: data)
            )
        } catch {
            throw ToasttyCLIError.runtime("failed to decode managed launch preparation: \(error.localizedDescription)")
        }
    }

    static func managedLaunchPreflightDecision(
        token: String,
        socketPath: String
    ) throws -> ManagedAgentLaunchPreflightDecision {
        let response = try ToasttySocketClient(socketPath: socketPath).send(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: preflightDecisionCommandName,
                payload: ["token": .string(token)]
            )
        )

        guard response.ok else {
            if let error = response.error {
                throw ToasttyCLIError.runtime("\(error.code): \(error.message)")
            }
            throw ToasttyCLIError.runtime("request failed")
        }

        guard let result = response.result else {
            throw ToasttyCLIError.runtime("request succeeded without a result")
        }

        let data = try JSONEncoder().encode(result)
        do {
            return try JSONDecoder().decode(ManagedAgentLaunchPreflightDecision.self, from: data)
        } catch {
            throw ToasttyCLIError.runtime("failed to decode managed launch preflight decision: \(error.localizedDescription)")
        }
    }

    private static func payload(for request: ManagedAgentLaunchRequest) -> [String: AutomationJSONValue] {
        var payload: [String: AutomationJSONValue] = [
            "agent": .string(request.agent.rawValue),
            "panelID": .string(request.panelID.uuidString),
            "argv": .array(request.argv.map(AutomationJSONValue.string)),
            "preflightPolicy": .string(request.preflightPolicy.rawValue),
        ]
        if let cwd = request.cwd {
            payload["cwd"] = .string(cwd)
        }
        if request.environment.isEmpty == false {
            payload["environment"] = .object(
                request.environment.reduce(into: [String: AutomationJSONValue]()) { result, entry in
                    result[entry.key] = .string(entry.value)
                }
            )
        }
        return payload
    }
}
