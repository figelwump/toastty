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
}
