import Foundation
import Darwin

public struct AutomationConfig: Equatable, Sendable {
    private static let automationArgument = "--automation"
    private static let automationEnvironmentFlag = "TOASTTY_AUTOMATION"
    private static let skipQuitConfirmationArgument = "--skip-quit-confirmation"
    private static let skipQuitConfirmationEnvironmentFlag = "TOASTTY_SKIP_QUIT_CONFIRMATION"

    public let runID: String
    public let fixtureName: String?
    public let artifactsDirectory: String?
    public let socketPath: String
    public let disableAnimations: Bool
    public let fixedLocaleIdentifier: String?
    public let fixedTimeZoneIdentifier: String?

    public init(
        runID: String,
        fixtureName: String?,
        artifactsDirectory: String?,
        socketPath: String,
        disableAnimations: Bool,
        fixedLocaleIdentifier: String?,
        fixedTimeZoneIdentifier: String?
    ) {
        self.runID = runID
        self.fixtureName = fixtureName
        self.artifactsDirectory = artifactsDirectory
        self.socketPath = socketPath
        self.disableAnimations = disableAnimations
        self.fixedLocaleIdentifier = fixedLocaleIdentifier
        self.fixedTimeZoneIdentifier = fixedTimeZoneIdentifier
    }

    public static func parse(arguments: [String], environment: [String: String]) -> AutomationConfig? {
        guard isAutomationSession(arguments: arguments, environment: environment) else { return nil }

        let runID = argumentValue(after: "--run-id", in: arguments)
            ?? environment["TOASTTY_RUN_ID"]
            ?? "default"

        let fixtureName = argumentValue(after: "--fixture", in: arguments)
            ?? environment["TOASTTY_FIXTURE"]

        let artifactsDirectory = argumentValue(after: "--artifacts-dir", in: arguments)
            ?? environment["TOASTTY_ARTIFACTS_DIR"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("toastty-automation-\(runID)")
                .path
        let socketPath = argumentValue(after: "--socket-path", in: arguments)
            ?? resolveServerSocketPath(environment: environment)

        return AutomationConfig(
            runID: runID,
            fixtureName: fixtureName,
            artifactsDirectory: artifactsDirectory,
            socketPath: socketPath,
            disableAnimations: arguments.contains("--disable-animations") || isEnabledFlag(environment["TOASTTY_DISABLE_ANIMATIONS"]),
            fixedLocaleIdentifier: environment["TOASTTY_FIXED_LOCALE"],
            fixedTimeZoneIdentifier: environment["TOASTTY_FIXED_TIMEZONE"]
        )
    }

    public static func shouldBypassInteractiveConfirmation(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        let isExplicitBypassRequested = arguments.contains(skipQuitConfirmationArgument)
            || isEnabledFlag(environment[skipQuitConfirmationEnvironmentFlag])
        return isExplicitBypassRequested || isAutomationSession(arguments: arguments, environment: environment)
    }

    public static func shouldBypassQuitConfirmation(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        shouldBypassInteractiveConfirmation(arguments: arguments, environment: environment)
    }

    private static func argumentValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }

        let value = arguments[index + 1]
        return value.hasPrefix("--") ? nil : value
    }

    public static func resolveSocketPath(environment: [String: String]) -> String {
        AutomationSocketLocator.resolveClientSocketPath(environment: environment)
    }

    public static func resolveServerSocketPath(
        environment: [String: String],
        processID: Int32 = getpid()
    ) -> String {
        if let explicitSocketPath = environment[ToasttyLaunchContextEnvironment.socketPathKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           explicitSocketPath.isEmpty == false {
            return explicitSocketPath
        }

        if let runtimeSocketFileURL = ToasttyRuntimePaths.resolve(environment: environment).automationSocketFileURL {
            return runtimeSocketFileURL.path
        }

        return AutomationSocketLocator.resolveServerSocketPath(
            environment: environment,
            processID: processID
        )
    }

    private static func isAutomationSession(arguments: [String], environment: [String: String]) -> Bool {
        let isArgAutomation = arguments.contains(automationArgument)
        let isEnvAutomation = isEnabledFlag(environment[automationEnvironmentFlag])
        return isArgAutomation || isEnvAutomation
    }

    static func isEnabledFlag(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
