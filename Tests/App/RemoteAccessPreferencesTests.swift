import RemoteProtocol
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct RemoteAccessPreferencesTests {
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
}
