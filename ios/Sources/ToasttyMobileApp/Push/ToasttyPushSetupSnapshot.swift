import Foundation

/// Only fixed categories, counts and timestamps can leave the push controller.
/// The last return describes a completed action, not a prediction of the next one.
struct ToasttyPushSetupSnapshot: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable { case unavailable, idle, awaitingProof, proofSaved, relayActive, enabled }
    enum Permission: String, Codable, Sendable { case undetermined, allowed, denied }
    enum Action: String, Codable, Sendable { case restore, reconcile, retry }
    enum ReturnReason: String, Codable, CaseIterable, Sendable {
        case completed, requested, background, reconcileInProgress, stateUnavailable
        case configurationUnavailable, unpaired, disconnected, unsupported, transientBackoff
        case credentialUnavailable, contextChanged, alertsOff, configurationMismatch
        case permissionRequired, tokenPending, invalidToken, relayCooldown, cleanupFull
        case awaitingProof, proofCompletionPending, cancelled, operationFailed
    }

    let stage: Stage
    let foreground: Bool
    let reconciling: Bool
    let activeRegistrationEnabled: Bool
    let permission: Permission
    let connected: Bool
    let desired: Bool
    let tokenPresent: Bool
    let configurationMatches: Bool
    let savedCooldownUntil: Date?
    let cooldownUntil: Date?
    let retryScheduledAt: Date?
    let cleanupCount: Int
    let lastAction: Action?
    let lastReturnReason: ReturnReason?
    let lastReturnAt: Date?
    let resultSequence: UInt64
}
