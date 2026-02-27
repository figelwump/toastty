import Foundation

public struct AutomationConfig: Equatable, Sendable {
    public let runID: String
    public let fixtureName: String?
    public let artifactsDirectory: String?
    public let disableAnimations: Bool
    public let fixedLocaleIdentifier: String?
    public let fixedTimeZoneIdentifier: String?

    public init(
        runID: String,
        fixtureName: String?,
        artifactsDirectory: String?,
        disableAnimations: Bool,
        fixedLocaleIdentifier: String?,
        fixedTimeZoneIdentifier: String?
    ) {
        self.runID = runID
        self.fixtureName = fixtureName
        self.artifactsDirectory = artifactsDirectory
        self.disableAnimations = disableAnimations
        self.fixedLocaleIdentifier = fixedLocaleIdentifier
        self.fixedTimeZoneIdentifier = fixedTimeZoneIdentifier
    }

    public static func parse(arguments: [String], environment: [String: String]) -> AutomationConfig? {
        let isArgAutomation = arguments.contains("--automation")
        let isEnvAutomation = environment["TOASTTY_AUTOMATION"] == "1"
        guard isArgAutomation || isEnvAutomation else { return nil }

        let runID = argumentValue(after: "--run-id", in: arguments)
            ?? environment["TOASTTY_RUN_ID"]
            ?? "default"

        let fixtureName = argumentValue(after: "--fixture", in: arguments)
        let artifactsDirectory = argumentValue(after: "--artifacts-dir", in: arguments)
            ?? environment["TOASTTY_ARTIFACTS_DIR"]

        return AutomationConfig(
            runID: runID,
            fixtureName: fixtureName,
            artifactsDirectory: artifactsDirectory,
            disableAnimations: environment["TOASTTY_DISABLE_ANIMATIONS"] == "1",
            fixedLocaleIdentifier: environment["TOASTTY_FIXED_LOCALE"],
            fixedTimeZoneIdentifier: environment["TOASTTY_FIXED_TIMEZONE"]
        )
    }

    private static func argumentValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }

        let value = arguments[index + 1]
        return value.hasPrefix("--") ? nil : value
    }
}
