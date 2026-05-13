import CoreState
import Foundation

struct TerminalPanelHostState: Equatable {
    let cwd: String
    let launchWorkingDirectory: String?

    init(cwd: String, launchWorkingDirectory: String?) {
        self.cwd = cwd
        self.launchWorkingDirectory = launchWorkingDirectory
    }

    init(terminalState: TerminalPanelState) {
        self.init(
            cwd: terminalState.cwd,
            launchWorkingDirectory: terminalState.launchWorkingDirectory
        )
    }

    var workingDirectorySeed: String {
        launchState.workingDirectorySeed
    }

    var expectedProcessWorkingDirectory: String? {
        launchState.expectedProcessWorkingDirectory
    }

    private var launchState: TerminalPanelState {
        TerminalPanelState(
            title: "",
            shell: "",
            cwd: cwd,
            launchWorkingDirectory: launchWorkingDirectory
        )
    }
}
