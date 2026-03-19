import CoreState
import Foundation
import Testing

struct AgentProfileCodableTests {
    @Test
    func roundTripsShortcutKeyThroughCodable() throws {
        let profile = AgentProfile(
            id: "codex",
            displayName: "Codex",
            argv: ["codex"],
            shortcutKey: "c"
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AgentProfile.self, from: data)

        #expect(decoded == profile)
        #expect(String(data: data, encoding: .utf8)?.contains("\"shortcutKey\":\"c\"") == true)
    }

    @Test
    func decodeRejectsMultiCharacterShortcutKey() {
        let payload = """
        {"id":"codex","displayName":"Codex","argv":["codex"],"shortcutKey":"ab"}
        """

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AgentProfile.self, from: Data(payload.utf8))
        }
    }
}
