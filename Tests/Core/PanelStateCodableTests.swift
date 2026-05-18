import CoreState
import Foundation
import Testing

struct PanelStateCodableTests {
    @Test
    func webPanelDefinitionsDeclareCapabilityProfiles() {
        #expect(WebPanelDefinition.browser.capabilityProfile == .networkAllowed)
        #expect(WebPanelDefinition.localDocument.capabilityProfile == .localOnly)
        #expect(WebPanelDefinition.scratchpad.capabilityProfile == .localOnly)
        #expect(WebPanelDefinition.diff.capabilityProfile == .localOnly)
    }

    @Test
    func panelStateRoundTripsCodable() throws {
        let resumeRecord = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/tmp/project",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let panels: [PanelState] = [
            .terminal(
                TerminalPanelState(
                    title: "T",
                    shell: "zsh",
                    cwd: "/tmp",
                    profileBinding: TerminalProfileBinding(profileID: "zmx"),
                    resumeRecord: resumeRecord
                )
            ),
            .web(
                WebPanelState(
                    definition: .browser,
                    initialURL: "https://example.com",
                    currentURL: "https://example.com/docs"
                )
            ),
            .web(
                WebPanelState(
                    definition: .localDocument,
                    title: "README.md",
                    filePath: "/tmp/project/README.md"
                )
            ),
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for panel in panels {
            let encoded = try encoder.encode(panel)
            let decoded = try decoder.decode(PanelState.self, from: encoded)
            #expect(decoded == panel)
        }
    }

    @Test
    func terminalPanelStateDecodesWhenResumeRecordIsAbsent() throws {
        let data = Data(
            """
            {
              "title": "T",
              "shell": "zsh",
              "cwd": "/tmp",
              "profileBinding": {
                "profileID": "zmx"
              }
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(TerminalPanelState.self, from: data)

        #expect(decoded.title == "T")
        #expect(decoded.profileBinding == TerminalProfileBinding(profileID: "zmx"))
        #expect(decoded.resumeRecord == nil)
    }
}
