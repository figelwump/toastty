import Foundation

enum TerminalLaunchReason: String, Equatable, Sendable {
    case create
    case restore
}

struct TerminalSurfaceLaunchConfiguration: Equatable, Sendable {
    var environmentVariables: [String: String]
    var initialInput: String?

    init(
        environmentVariables: [String: String] = [:],
        initialInput: String? = nil
    ) {
        self.environmentVariables = environmentVariables
        self.initialInput = initialInput
    }

    var normalizedInitialInput: String? {
        guard let initialInput else { return nil }
        let trimmed = initialInput.trimmingCharacters(in: .newlines)
        guard trimmed.isEmpty == false else { return nil }
        return initialInput.hasSuffix("\n") ? initialInput : initialInput + "\n"
    }

    var isEmpty: Bool {
        environmentVariables.isEmpty && normalizedInitialInput == nil
    }

    static let empty = TerminalSurfaceLaunchConfiguration()
}
