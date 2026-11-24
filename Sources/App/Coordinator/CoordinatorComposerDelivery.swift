import Foundation

/// While the coordinator's turn runs: what Send does with the text.
struct CoordinatorComposerDelivery: Equatable {
    /// Send types the text into the running turn. Otherwise the text waits
    /// in the queue for the turn's end.
    var steers: Bool
    /// The running turn can take a steer now.
    var canSteer: Bool

    /// The key that queues while a turn runs.
    #if os(Linux)
    static let queueKeyName = "Ctrl+Return"
    #else
    static let queueKeyName = "Command-Return"
    #endif

    static func sendLabel(_ delivery: CoordinatorComposerDelivery?) -> String {
        guard let delivery else { return "Send" }
        return delivery.steers ? "Steer" : "Queue"
    }

    static func sendHelp(_ delivery: CoordinatorComposerDelivery?) -> String {
        guard let delivery else { return "Send (Return). Shift-Return starts a new line." }
        return delivery.steers
            ? "Steer: add to the running turn (Return). \(queueKeyName) queues. Shift-Return starts a new line."
            : "Queue: send after this turn (Return). Shift-Return starts a new line."
    }

    static func chipHelp(_ delivery: CoordinatorComposerDelivery) -> String {
        if delivery.canSteer == false {
            return "The running turn cannot take a steer now, so the message waits for the turn's end."
        }
        return "Steer adds the message to the running turn. Queue sends it after this turn."
    }
}
