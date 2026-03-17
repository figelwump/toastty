@testable import ToasttyApp
import Testing

struct TerminalSurfaceLaunchConfigurationTests {
    @Test
    func normalizedInitialInputAppendsTrailingNewlineWhenNeeded() {
        let configuration = TerminalSurfaceLaunchConfiguration(initialInput: "zmx attach toastty.$TOASTTY_PANEL_ID")

        #expect(configuration.normalizedInitialInput == "zmx attach toastty.$TOASTTY_PANEL_ID\n")
    }

    @Test
    func normalizedInitialInputPreservesExistingTrailingNewline() {
        let configuration = TerminalSurfaceLaunchConfiguration(initialInput: "ssh prod\n")

        #expect(configuration.normalizedInitialInput == "ssh prod\n")
    }

    @Test
    func normalizedInitialInputTreatsBlankCommandsAsEmpty() {
        let configuration = TerminalSurfaceLaunchConfiguration(initialInput: "\n\n")

        #expect(configuration.normalizedInitialInput == nil)
        #expect(configuration.isEmpty)
    }
}
