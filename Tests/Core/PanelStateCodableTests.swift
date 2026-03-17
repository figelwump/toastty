import CoreState
import Foundation
import Testing

struct PanelStateCodableTests {
    @Test
    func panelStateRoundTripsCodable() throws {
        let panels: [PanelState] = [
            .terminal(
                TerminalPanelState(
                    title: "T",
                    shell: "zsh",
                    cwd: "/tmp",
                    profileBinding: TerminalProfileBinding(profileID: "zmx")
                )
            ),
            .diff(DiffPanelState(showStaged: true, mode: .followFocusedTerminal, loadingState: .computing)),
            .markdown(MarkdownPanelState(sourcePanelID: UUID(), filePath: "/tmp/README.md", rawMarkdown: "# title")),
            .scratchpad(ScratchpadPanelState(documentID: UUID())),
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for panel in panels {
            let encoded = try encoder.encode(panel)
            let decoded = try decoder.decode(PanelState.self, from: encoded)
            #expect(decoded == panel)
        }
    }
}
