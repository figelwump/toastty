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
            .web(WebPanelState(definition: .browser, url: "https://example.com")),
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
