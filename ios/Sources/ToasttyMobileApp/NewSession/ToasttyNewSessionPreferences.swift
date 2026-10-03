import Foundation

/// The phone's own memory of new-session choices: the last agent, and per
/// agent the models picked recently and the last model and effort used.
struct ToasttyNewSessionPreferences {
    static let maximumRecentModels = 5

    private static let lastAgentKey = "toastty-mobile-new-session-last-agent"
    private static let agentKeyPrefix = "toastty-mobile-new-session-agent-"

    private struct AgentChoices: Codable, Equatable {
        /// Most recent first.
        var recentModels: [String] = []
        /// `nil` when the last start used the profile's default.
        var lastModel: String?
        var lastEffort: String?
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastAgentID: String? {
        defaults.string(forKey: Self.lastAgentKey)
    }

    func recentModels(forAgent profileID: String) -> [String] {
        choices(forAgent: profileID).recentModels
    }

    func lastModel(forAgent profileID: String) -> String? {
        choices(forAgent: profileID).lastModel
    }

    func lastEffort(forAgent profileID: String) -> String? {
        choices(forAgent: profileID).lastEffort
    }

    /// Records the choices of a start the Mac accepted.
    func recordStart(agentID: String, model: String?, effort: String?) {
        var choices = choices(forAgent: agentID)
        if let model {
            choices.recentModels = Array(
                ([model] + choices.recentModels.filter { $0 != model }).prefix(Self.maximumRecentModels)
            )
        }
        choices.lastModel = model
        choices.lastEffort = effort
        if let data = try? JSONEncoder().encode(choices) {
            defaults.set(data, forKey: Self.agentKeyPrefix + agentID)
        }
        defaults.set(agentID, forKey: Self.lastAgentKey)
    }

    private func choices(forAgent profileID: String) -> AgentChoices {
        guard let data = defaults.data(forKey: Self.agentKeyPrefix + profileID),
              let choices = try? JSONDecoder().decode(AgentChoices.self, from: data) else {
            return AgentChoices()
        }
        return choices
    }
}
