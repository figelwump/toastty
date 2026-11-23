import RemoteProtocol
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct RemoteAccessPreferencesTests {
    @Test func usersToasttyKeepsTheDefaultPort() throws {
        try withDefaults { defaults in
            let paths = ToasttyRuntimePaths.resolve(homeDirectoryPath: "/Users/someone", environment: [:])

            #expect(RemoteAccessPreferences.loadPort(userDefaults: defaults, runtimePaths: paths) == 42_871)
        }
    }

    @Test func isolatedInstancesGetTheirOwnPortThatStaysTheSame() throws {
        try withDefaults { defaults in
            let environments: [[String: String]] = [
                [ToasttyRuntimePaths.worktreeRootEnvironmentKey: "/Users/someone/repos/toastty-feature-a"],
                [ToasttyRuntimePaths.worktreeRootEnvironmentKey: "/Users/someone/repos/toastty-feature-b"],
                [ToasttyRuntimePaths.environmentKey: "/tmp/toastty-check/runtime-home"],
            ]
            let ports = environments.map { environment in
                RemoteAccessPreferences.loadPort(
                    userDefaults: defaults,
                    runtimePaths: .resolve(homeDirectoryPath: "/Users/someone", environment: environment)
                )
            }
            // A fixed value proves that the port does not depend on the
            // process: the next launch must find the same Tailscale Serve
            // mapping. Changing it moves every dev instance's mapping.
            #expect(ports == [43_535, 43_836, 43_666])
            #expect(ports.allSatisfy(RemoteAccessPreferences.isolatedPortRange.contains))
        }
    }

    @Test func savedPortWinsAndAnInvalidOneIsIgnored() throws {
        try withDefaults { defaults in
            let isolated = ToasttyRuntimePaths.resolve(
                homeDirectoryPath: "/Users/someone",
                environment: [ToasttyRuntimePaths.environmentKey: "/tmp/toastty-check/runtime-home"]
            )
            let instancePort = RemoteAccessPreferences.instancePort(runtimePaths: isolated)

            defaults.set(50_123, forKey: "toastty.remoteAccess.port")
            #expect(RemoteAccessPreferences.loadPort(userDefaults: defaults, runtimePaths: isolated) == 50_123)

            for invalid in [80, 70_000, -1] {
                defaults.set(invalid, forKey: "toastty.remoteAccess.port")
                #expect(RemoteAccessPreferences.loadPort(userDefaults: defaults, runtimePaths: isolated) == instancePort)
            }
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "toastty-remote-access-preferences-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test func discardsLegacyWriteEnabledConversationAllowlist() throws {
        let suiteName = "toastty-remote-access-preferences-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyKey = "toastty.remoteAccess.writeEnabledConversations"
        defaults.set([UUID().uuidString], forKey: legacyKey)

        RemoteAccessPreferences.discardLegacyWriteEnabledConversations(userDefaults: defaults)

        #expect(defaults.object(forKey: legacyKey) == nil)
    }

    @Test func sessionWritePolicyDefaultsOnAndKeepsDisableScopedToConversation() {
        let conversationID = RemoteConversationID()
        let otherConversationID = RemoteConversationID()
        var policy = RemoteSessionWritePolicy()

        #expect(policy.isEnabled(for: conversationID))
        let didDisable = policy.setEnabled(false, for: conversationID)
        #expect(didDisable)
        #expect(policy.isEnabled(for: conversationID) == false)
        let didDisableAgain = policy.setEnabled(false, for: conversationID)
        #expect(didDisableAgain == false)
        #expect(policy.isEnabled(for: otherConversationID))

        let didEnable = policy.setEnabled(true, for: conversationID)

        #expect(didEnable)
        #expect(policy.isEnabled(for: conversationID))
    }

    @Test func disabledSessionWritePolicyPublishesDedicatedUnavailableReason() {
        let conversationID = RemoteConversationID()
        let otherConversationID = RemoteConversationID()
        let providerAvailability = RemoteInputAvailability.openPrompt(
            epoch: RemoteInputEpoch(bindingID: UUID(), counter: 7)
        )
        var policy = RemoteSessionWritePolicy()

        _ = policy.setEnabled(false, for: conversationID)

        #expect(policy.inputAvailability(
            providerAvailability: providerAvailability,
            for: conversationID
        ) == .unavailable(reason: .sessionWritesDisabled))
        #expect(policy.inputAvailability(
            providerAvailability: providerAvailability,
            for: otherConversationID
        ) == providerAvailability)
    }
}
