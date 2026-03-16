import CoreState
import Testing

struct AgentKindTests {
    @Test
    func displayNameUsesKnownAgentLabels() {
        #expect(AgentKind.codex.displayName == "Codex")
        #expect(AgentKind.claude.displayName == "Claude Code")
    }

    @Test
    func displayNameHumanizesCustomAgentIDs() throws {
        let gemini = try #require(AgentKind(rawValue: "gemini-cli"))
        #expect(gemini.displayName == "Gemini Cli")
    }
}
