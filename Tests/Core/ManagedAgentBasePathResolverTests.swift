@testable import CoreState
import XCTest

final class ManagedAgentBasePathResolverTests: XCTestCase {
    private final class ProbeCapture: @unchecked Sendable {
        var shellPath: String?
        var arguments: [String] = []
        var environment: [String: String] = [:]
    }

    func testResolveUsesLoginShellProbeOutputWhenAvailable() {
        let capture = ProbeCapture()
        let resolver = ManagedAgentBasePathResolver(
            environment: [
                "PATH": "/usr/bin:/bin",
                "SHELL": "/usr/local/bin/fish",
                "TOASTTY_AGENT_SHIM_DIR": "/tmp/toastty-shim",
            ],
            fallbackPath: "/usr/bin:/bin",
            timeout: 3,
            loginShellPathProvider: { "/bin/zsh" },
            shellCommandRunner: { shellPath, arguments, environment, _ in
                capture.shellPath = shellPath
                capture.arguments = arguments
                capture.environment = environment
                return ManagedAgentBasePathResolver.ProbeOutput(
                    exitCode: 0,
                    stdout: """
                    noise before
                    __TOASTTY_AGENT_BASE_PATH_START__/usr/bin:/bin:/Users/test/.bun/bin:/Users/test/.local/bin__TOASTTY_AGENT_BASE_PATH_END__
                    """,
                    stderr: ""
                )
            }
        )

        let resolvedPath = resolver.resolve()

        XCTAssertEqual(capture.shellPath, "/bin/zsh")
        XCTAssertEqual(
            capture.arguments,
            [
                "-ilc",
                "printf '%s' '__TOASTTY_AGENT_BASE_PATH_START__'; printf '%s' \"$PATH\"; printf '%s' '__TOASTTY_AGENT_BASE_PATH_END__'",
            ]
        )
        XCTAssertNil(capture.environment["TOASTTY_AGENT_SHIM_DIR"])
        XCTAssertEqual(resolvedPath, "/usr/bin:/bin:/Users/test/.bun/bin:/Users/test/.local/bin")
    }

    func testResolveExecutableUsesLoginShellProbeOutputWhenAvailable() {
        let capture = ProbeCapture()
        let resolver = ManagedAgentBasePathResolver(
            environment: [
                "PATH": "/usr/bin:/bin",
                "TOASTTY_AGENT_SHIM_DIR": "/tmp/toastty-shim",
            ],
            fallbackPath: "/usr/bin:/bin",
            timeout: 3,
            loginShellPathProvider: { "/bin/zsh" },
            shellCommandRunner: { shellPath, arguments, environment, _ in
                capture.shellPath = shellPath
                capture.arguments = arguments
                capture.environment = environment
                return ManagedAgentBasePathResolver.ProbeOutput(
                    exitCode: 0,
                    stdout: """
                    __TOASTTY_AGENT_BASE_PATH_START__/usr/bin:/bin:/Users/test/.bun/bin:/Users/test/.nvm/bin__TOASTTY_AGENT_BASE_PATH_END__
                    __TOASTTY_AGENT_EXECUTABLE_PATH_START__/Users/test/.bun/bin/codex__TOASTTY_AGENT_EXECUTABLE_PATH_END__
                    """,
                    stderr: ""
                )
            }
        )

        let resolution = resolver.resolveExecutable(commandName: "codex")

        XCTAssertEqual(capture.shellPath, "/bin/zsh")
        XCTAssertEqual(
            capture.arguments,
            [
                "-ilc",
                "printf '%s' '__TOASTTY_AGENT_BASE_PATH_START__'; printf '%s' \"$PATH\"; printf '%s' '__TOASTTY_AGENT_BASE_PATH_END__'; resolved=$(command -v 'codex' 2>/dev/null || true); if [ -n \"$resolved\" ]; then printf '%s' '__TOASTTY_AGENT_EXECUTABLE_PATH_START__'; printf '%s' \"$resolved\"; printf '%s' '__TOASTTY_AGENT_EXECUTABLE_PATH_END__'; fi",
            ]
        )
        XCTAssertNil(capture.environment["TOASTTY_AGENT_SHIM_DIR"])
        XCTAssertEqual(resolution?.executablePath, "/Users/test/.bun/bin/codex")
        XCTAssertEqual(resolution?.path, "/usr/bin:/bin:/Users/test/.bun/bin:/Users/test/.nvm/bin")
    }

    func testResolveFallsBackWhenProbeOutputIsMissingMarkers() {
        let resolver = ManagedAgentBasePathResolver(
            environment: ["PATH": "/usr/bin:/bin"],
            fallbackPath: "/usr/bin:/bin",
            timeout: 3,
            loginShellPathProvider: { "/opt/homebrew/bin/fish" },
            shellCommandRunner: { _, _, _, _ in
                ManagedAgentBasePathResolver.ProbeOutput(
                    exitCode: 0,
                    stdout: "missing markers",
                    stderr: ""
                )
            }
        )

        XCTAssertEqual(resolver.resolve(), "/usr/bin:/bin")
    }

    func testFishProbeArgumentsUseInteractiveLoginShell() {
        XCTAssertEqual(
            ManagedAgentBasePathResolver.probeArguments(forShellPath: "/opt/homebrew/bin/fish"),
            [
                "-ilc",
                "printf '%s' '__TOASTTY_AGENT_BASE_PATH_START__'; string join ':' $PATH; printf '%s' '__TOASTTY_AGENT_BASE_PATH_END__'",
            ]
        )
    }

    func testExecutableProbeArgumentsEscapeSingleQuotes() {
        XCTAssertEqual(
            ManagedAgentBasePathResolver.executableProbeArguments(
                forShellPath: "/bin/zsh",
                commandName: "claude's"
            ),
            [
                "-ilc",
                "printf '%s' '__TOASTTY_AGENT_BASE_PATH_START__'; printf '%s' \"$PATH\"; printf '%s' '__TOASTTY_AGENT_BASE_PATH_END__'; resolved=$(command -v 'claude'\"'\"'s' 2>/dev/null || true); if [ -n \"$resolved\" ]; then printf '%s' '__TOASTTY_AGENT_EXECUTABLE_PATH_START__'; printf '%s' \"$resolved\"; printf '%s' '__TOASTTY_AGENT_EXECUTABLE_PATH_END__'; fi",
            ]
        )
    }
}
