import CoreState
import Foundation

enum ManagedAgentLaunchSocketClient {
    private static let commandName = "agent.prepare_managed_launch"

    static func prepareManagedLaunch(
        _ request: ManagedAgentLaunchRequest,
        socketPath: String
    ) throws -> ManagedAgentLaunchPlan {
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
            return try JSONDecoder().decode(ManagedAgentLaunchPlan.self, from: data)
        } catch {
            throw ToasttyCLIError.runtime("failed to decode managed launch plan: \(error.localizedDescription)")
        }
    }

    private static func payload(for request: ManagedAgentLaunchRequest) -> [String: AutomationJSONValue] {
        var payload: [String: AutomationJSONValue] = [
            "agent": .string(request.agent.rawValue),
            "panelID": .string(request.panelID.uuidString),
            "argv": .array(request.argv.map(AutomationJSONValue.string)),
        ]
        if let cwd = request.cwd {
            payload["cwd"] = .string(cwd)
        }
        return payload
    }
}
