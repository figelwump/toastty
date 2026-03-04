import CoreState
import Foundation
import Testing

struct PanelStateCodableTests {
    @Test
    func panelStateRoundTripsCodable() throws {
        let panels: [PanelState] = [
            .terminal(TerminalPanelState(title: "T", shell: "zsh", cwd: "/tmp")),
            .diff(DiffPanelState(showStaged: true, mode: .followFocusedTerminal, loadingState: .computing)),
            .markdown(MarkdownPanelState(sourcePanelID: UUID(), filePath: "/tmp/README.md", rawMarkdown: "# title")),
            .scratchpad(ScratchpadPanelState(documentID: UUID())),
            .screenshots(ScreenshotsPanelState()),
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
    func decodingScreenshotsPanelWithoutPayloadFails() throws {
        let invalidJSON = #"{"kind":"screenshots"}"#.data(using: .utf8) ?? Data()
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PanelState.self, from: invalidJSON)
        }
    }
}
