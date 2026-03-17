import CoreState
import Testing

struct ToasttyLogConfigurationTests {
    @Test
    func defaultConfigurationUsesInfoLevelAndLibraryLogFile() {
        let config = ToasttyLogConfiguration.fromEnvironment([:])

        #expect(config.enabled == true)
        #expect(config.minimumLevel == .info)
        #expect(config.filePath?.hasSuffix("/Library/Logs/Toastty/toastty.log") == true)
        #expect(config.mirrorToStderr == false)
    }

    @Test
    func environmentOverridesConfiguration() {
        let config = ToasttyLogConfiguration.fromEnvironment([
            "TOASTTY_LOG_DISABLE": "1",
            "TOASTTY_LOG_LEVEL": "debug",
            "TOASTTY_LOG_FILE": "/tmp/custom-toastty.log",
            "TOASTTY_LOG_STDERR": "true",
        ])

        #expect(config.enabled == false)
        #expect(config.minimumLevel == .debug)
        #expect(config.filePath == "/tmp/custom-toastty.log")
        #expect(config.mirrorToStderr == true)
    }

    @Test
    func noneLogFileDisablesFileSink() {
        let config = ToasttyLogConfiguration.fromEnvironment([
            "TOASTTY_LOG_FILE": "none",
        ])

        #expect(config.filePath == nil)
    }

    @Test
    func runtimeHomeChangesDefaultLogPath() {
        let config = ToasttyLogConfiguration.fromEnvironment(
            ["TOASTTY_RUNTIME_HOME": "/tmp/toastty-runtime-log-tests/runtime-home"],
            homeDirectoryPath: "/tmp/ignored-home"
        )

        #expect(config.filePath == "/tmp/toastty-runtime-log-tests/runtime-home/logs/toastty.log")
    }

    @Test
    func worktreeRootChangesDefaultLogPath() {
        let config = ToasttyLogConfiguration.fromEnvironment(
            ["TOASTTY_DEV_WORKTREE_ROOT": "/tmp/toastty-runtime-log-tests/worktrees/main"],
            homeDirectoryPath: "/tmp/ignored-home"
        )

        #expect(config.filePath?.contains("/tmp/toastty-runtime-log-tests/worktrees/main/artifacts/dev-runs/worktree-main-") == true)
        #expect(config.filePath?.hasSuffix("/runtime-home/logs/toastty.log") == true)
    }
}
