import Foundation
import Testing
@testable import ToasttyApp

struct TailscaleServeSetupTests {
    // Failure modes: occupied ports, public ingress, foreground ownership,
    // malformed status, partial command success, approval waits, and cancellation.
    private let origin = "https://mac.tailnet.ts.net"
    private let port: UInt16 = 42_871

    @Test func acceptsEmptyConfigurationAndUnrelatedServices() throws {
        for json in ["null", "{}", #"{"TCP":{"8443":{"HTTPS":true}},"Web":{"other.tailnet.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://localhost:3000"}}}},"Services":{"svc:other":{}}}"#] {
            #expect(try state(json) == .available)
        }
    }

    @Test func reusesEquivalentPrivateRootProxiesWithoutChangingOtherRoutes() throws {
        for proxy in ["http://127.0.0.1:42871", "http://localhost:42871/"] {
            #expect(try state(mapping(proxy: proxy, extraPath: true)) == .configured)
        }
    }

    @Test func refusesOccupiedPortsAndShadowingForegroundListeners() {
        for json in [
            mapping(proxy: "http://localhost:3000"),
            #"{"TCP":{"443":{"TCPForward":"localhost:42871"}}}"#,
            #"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tailnet.ts.net:443":{"Handlers":{"/other":{"Proxy":"http://localhost:3000"}}}}}"#,
            #"{"Foreground":{"session":{"TCP":{"443":{"HTTPS":true}}}}}"#,
        ] {
            #expect(throws: TailscaleServeSetupError.portInUse(443)) { try state(json) }
        }
    }

    @Test func refusesPublicIngressIncludingForegroundAndOtherHostnames() {
        for json in [
            #"{"AllowFunnel":{"mac.tailnet.ts.net:443":true}}"#,
            #"{"AllowFunnel":{"old.tailnet.ts.net:443":true}}"#,
            #"{"Foreground":{"session":{"AllowFunnel":{"mac.tailnet.ts.net:443":true}}}}"#,
            #"{"AllowFunnel":{"mac.tailnet.ts.net:8443":true},"Web":{"mac.tailnet.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://localhost:42871"}}}}}"#,
        ] {
            #expect(throws: TailscaleServeSetupError.funnelEnabled) { try state(json) }
        }
    }

    @Test func malformedStatusNeverMeansUnconfigured() {
        for json in ["", "[]", "false", #"{"TCP":[]}"#, #"{"AllowFunnel":{"mac.tailnet.ts.net:443":"true"}}"#] {
            #expect(throws: TailscaleServeSetupError.statusUnavailable) { try state(json) }
        }
    }

    @Test func approvalLinksMustBeStandaloneAndBelongToTailscale() {
        let approved = URL(string: "https://login.tailscale.com/f/serve?node=fixture")!
        #expect(TailscaleServeSetup.approvalURL(in: Data("Enable Serve\n  \(approved)\n".utf8)) == approved)
        for text in [
            "https://login.tailscale.com.evil.test/f/serve",
            "http://login.tailscale.com/f/serve",
            "https://user@login.tailscale.com/f/serve",
            "https://login.tailscale.com:8443/f/serve",
            "https://login.tailscale.com/admin/dns",
            "https://login.tailscale.com/f/serve#fragment",
            "prefix https://login.tailscale.com/f/serve",
        ] {
            #expect(TailscaleServeSetup.approvalURL(in: Data(text.utf8)) == nil)
        }
    }

    @Test func createsMappingThroughExecutableThenVerifiesActualState() async throws {
        let fixture = try Fixture(before: "null", after: mapping())
        defer { fixture.remove() }
        let result = try await fixture.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true)
        #expect(result == origin)
        #expect(try fixture.commands.contains("serve --bg --https=443 http://127.0.0.1:42871"))
        #expect(try fixture.commands.last == "status --json --peers=false")
    }

    @Test func readOnlyAndExistingConfigurationsDoNotRunMutation() async throws {
        let fixture = try Fixture(before: mapping())
        defer { fixture.remove() }
        for configure in [false, true] {
            #expect(try await fixture.setup.run(port: port, configuredOrigin: origin, configureIfNeeded: configure) == origin)
        }
        #expect(try fixture.commands.allSatisfy { !$0.contains("--bg") })
        let absent = try Fixture(before: "{}")
        defer { absent.remove() }
        await expectFailure(.notConfigured) {
            try await absent.setup.run(port: port, configuredOrigin: "", configureIfNeeded: false)
        }
        #expect(try absent.commands.allSatisfy { !$0.contains("--bg") })
    }

    @Test func conflictsAndDifferentSavedOriginsNeverRunMutation() async throws {
        let fixture = try Fixture(before: mapping(proxy: "http://localhost:3000"))
        defer { fixture.remove() }
        await expectFailure(.portInUse(443)) {
            try await fixture.setup.run(port: port, configuredOrigin: origin, configureIfNeeded: true)
        }
        await expectFailure(.originMismatch) {
            try await fixture.setup.run(port: port, configuredOrigin: "https://other.tailnet.ts.net", configureIfNeeded: true)
        }
        #expect(try fixture.commands.allSatisfy { !$0.contains("--bg") })
    }

    @Test func choosesFallbackWithoutReplacingTheOccupied443Mapping() async throws {
        let occupied = mapping(proxy: "http://localhost:3000")
        let combined = try merged(occupied, mapping(httpsPort: 8443))
        let fixture = try Fixture(before: occupied, after: combined)
        defer { fixture.remove() }
        #expect(try await fixture.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true) == origin + ":8443")
        #expect(try fixture.commands.filter { $0.contains("--bg") } == ["serve --bg --https=8443 http://127.0.0.1:42871"])
        #expect(try state(String(contentsOf: fixture.directory.appendingPathComponent("status"), encoding: .utf8), origin: origin + ":8443") == .configured)
    }

    @Test func skipsOccupiedFallbacksAndStopsWhenBoundedCandidatesAreFull() async throws {
        let occupied = try merged(mapping(proxy: "http://localhost:3000"), mapping(proxy: "http://localhost:3001", httpsPort: 8443))
        let fixture = try Fixture(before: occupied, after: merged(occupied, mapping(httpsPort: 8444)))
        defer { fixture.remove() }
        #expect(try await fixture.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true) == origin + ":8444")
        #expect(try fixture.commands.filter { $0.contains("--bg") } == ["serve --bg --https=8444 http://127.0.0.1:42871"])
        let full = try Fixture(before: merged(occupied,
            mapping(proxy: "http://localhost:3002", httpsPort: 8444),
            mapping(proxy: "http://localhost:3003", httpsPort: 8445),
            mapping(proxy: "http://localhost:3004", httpsPort: 8446),
            mapping(proxy: "http://localhost:3005", httpsPort: 8447)))
        defer { full.remove() }
        await expectFailure(.noAvailableHTTPSPort) {
            try await full.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true)
        }
        #expect(try full.commands.allSatisfy { !$0.contains("--bg") })
    }

    @Test func secondPreflightRejectsAConcurrentEditWithoutSelectingAnotherPort() async throws {
        let occupied443 = mapping(proxy: "http://localhost:3000")
        let fixture = try Fixture(
            before: occupied443,
            changesOnPreflight: merged(occupied443, mapping(proxy: "http://localhost:3001", httpsPort: 8443))
        )
        defer { fixture.remove() }
        await expectFailure(.portInUse(8443)) {
            try await fixture.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true)
        }
        #expect(try fixture.commands.allSatisfy { !$0.contains("--bg") })
    }

    @Test func enabledFunnelWithoutHandlersReservesAFallbackPort() async throws {
        let before = try merged(mapping(proxy: "http://localhost:3000"), #"{"AllowFunnel":{"mac.tailnet.ts.net:8443":true}}"#)
        let fixture = try Fixture(before: before, after: merged(before, mapping(httpsPort: 8444)))
        defer { fixture.remove() }
        #expect(try await fixture.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true) == origin + ":8444")
    }

    @Test func savedFallbackAndInterruptedSetupReuseMappingEvenAfter443BecomesFree() async throws {
        let fixture = try Fixture(before: mapping(httpsPort: 8444))
        defer { fixture.remove() }
        for saved in [origin + ":8444", ""] {
            for configure in [false, true] {
                #expect(try await fixture.setup.run(port: port, configuredOrigin: saved, configureIfNeeded: configure) == origin + ":8444")
            }
        }
        #expect(try fixture.commands.allSatisfy { !$0.contains("--bg") })
    }

    @Test func savedFallbackIsRestoredOnlyByExplicitSetup() async throws {
        let fixture = try Fixture(before: "{}", after: mapping(httpsPort: 8445))
        defer { fixture.remove() }
        await expectFailure(.notConfigured) {
            try await fixture.setup.run(port: port, configuredOrigin: origin + ":8445", configureIfNeeded: false)
        }
        #expect(try fixture.commands.allSatisfy { !$0.contains("--bg") })
        #expect(try await fixture.setup.run(port: port, configuredOrigin: origin + ":8445", configureIfNeeded: true) == origin + ":8445")
        #expect(try fixture.commands.contains("serve --bg --https=8445 http://127.0.0.1:42871"))
    }

    @Test func unrelatedFunnelOccupiesAPortButBackendExposureAlwaysBlocksSetup() async throws {
        let publicOther = #"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tailnet.ts.net:443":{"Handlers":{"/":{"Proxy":"http://localhost:3000"}}}},"AllowFunnel":{"mac.tailnet.ts.net:443":true}}"#
        let fixture = try Fixture(before: publicOther, after: merged(publicOther, mapping(httpsPort: 8443)))
        defer { fixture.remove() }
        #expect(try await fixture.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true) == origin + ":8443")
        for json in [
            #"{"AllowFunnel":{"mac.tailnet.ts.net:10000":true},"TCP":{"10000":{"TCPForward":"127.0.0.1:42871","TerminateTLS":"mac.tailnet.ts.net"}}}"#,
            #"{"AllowFunnel":{"mac.tailnet.ts.net:10000":true},"Web":{"mac.tailnet.ts.net:10000":{"Handlers":{"/other":{"Proxy":"https+insecure://localhost:42871/path"}}}}}"#,
            #"{"AllowFunnel":{"mac.tailnet.ts.net:10000":true},"Foreground":{"session":{"Web":{"mac.tailnet.ts.net:10000":{"Handlers":{"/":{"Proxy":"http://localhost:42871"}}}}}}}"#,
        ] {
            let blocked = try Fixture(before: json)
            defer { blocked.remove() }
            await expectFailure(.funnelEnabled) {
                try await blocked.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true)
            }
            #expect(try blocked.commands.allSatisfy { !$0.contains("--bg") })
        }
    }

    @Test func funnelChainsIntoAnyExistingGatewayMappingBlockEverySelection() async throws {
        let exposure = try merged(mapping(),
            #"{"Web":{"mac.tailnet.ts.net:10000":{"Handlers":{"/":{"Proxy":"https://mac.tailnet.ts.net:8444"}}},"mac.tailnet.ts.net:8444":{"Handlers":{"/app":{"Proxy":"https+insecure://mac.tailnet.ts.net"}}}},"AllowFunnel":{"mac.tailnet.ts.net:10000":true}}"#)
        for saved in ["", origin + ":8445"] {
            let fixture = try Fixture(before: exposure)
            defer { fixture.remove() }
            await expectFailure(.funnelEnabled) {
                try await fixture.setup.run(port: port, configuredOrigin: saved, configureIfNeeded: true)
            }
            #expect(try fixture.commands.allSatisfy { !$0.contains("--bg") })
        }
    }

    @Test func funnelBackendPortAliasesAndUnknownTargetsFailClosed() throws {
        for target in ["http://0.0.0.0:42871", "http://[::]:42871", ":42871", "http://localhost.:42871", "http://[::ffff:127.0.0.1]:42871", "not a URL"] {
            let json = #"{"AllowFunnel":{"mac.tailnet.ts.net:10000":true},"Web":{"mac.tailnet.ts.net:10000":{"Handlers":{"/":{"Proxy":""# + target + #""}}}}}"#
            #expect(throws: TailscaleServeSetupError.funnelEnabled) { try state(json) }
        }
    }

    @Test func approvalExitZeroIsNotSuccessfulSetup() async throws {
        let fixture = try Fixture(before: "{}", output: "https://login.tailscale.com/f/serve?node=fixture")
        defer { fixture.remove() }
        await expectFailure(.approvalRequired(URL(string: "https://login.tailscale.com/f/serve?node=fixture")!)) {
            try await fixture.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true)
        }
    }

    @Test func timedOutApprovalWaitIsReapedAndOffersBrowserRecovery() async throws {
        let fixture = try Fixture(before: "{}", output: "https://login.tailscale.com/f/serve?node=fixture", stalls: true)
        defer { fixture.remove() }
        await expectFailure(.approvalRequired(URL(string: "https://login.tailscale.com/f/serve?node=fixture")!)) {
            try await fixture.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true)
        }
    }

    @Test func failedCommandCanStillHaveConfiguredMapping() async throws {
        let fixture = try Fixture(before: "{}", after: mapping(), exitCode: 1)
        defer { fixture.remove() }
        #expect(try await fixture.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true) == origin)
        let failed = try Fixture(before: "{}", exitCode: 1)
        defer { failed.remove() }
        await expectFailure(.configurationFailed) {
            try await failed.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true)
        }
    }

    @Test func profileChangeBeforeMutationCannotWriteOnAnotherTailnet() async throws {
        let fixture = try Fixture(before: "{}", changesIdentityBeforeWrite: true)
        defer { fixture.remove() }
        await expectFailure(.identityChanged) {
            try await fixture.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true)
        }
        #expect(try fixture.commands.allSatisfy { !$0.contains("--bg") })
    }

    @Test func profileChangeAfterMutationCannotReportSuccess() async throws {
        // The new profile has a different hostname as well as a different ID.
        // Its resulting mapping must not be mislabeled as an occupied port.
        let fixture = try Fixture(before: "{}", after: mapping().replacingOccurrences(of: "mac.tailnet", with: "other.tailnet"), changesIdentity: true)
        defer { fixture.remove() }
        await expectFailure(.identityChanged) {
            try await fixture.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true)
        }
    }

    @Test func unknownFailureOutputDoesNotBecomeAnApprovalLink() async throws {
        let fixture = try Fixture(before: "{}", output: "https://other.example/f/serve", exitCode: 1)
        defer { fixture.remove() }
        await expectFailure(.configurationFailed) {
            try await fixture.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true)
        }
    }

    @Test func cancellationNeverStartsAnotherClientOrPublishesSuccess() async throws {
        let fixture = try Fixture(before: "{}", stalls: true)
        defer { fixture.remove() }
        let task = Task { try await fixture.setup.run(port: port, configuredOrigin: "", configureIfNeeded: true) }
        for _ in 0..<100 {
            if (try? fixture.commands.contains(where: { $0.contains("--bg") })) == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch {
            Issue.record("Expected cancellation, got \(type(of: error))")
        }
    }

    private func state(_ json: String, origin: String? = nil) throws -> TailscaleServeConfigurationState {
        try TailscaleServeSetup.configurationState(from: Data(json.utf8), origin: origin ?? self.origin, port: port)
    }

    private func mapping(proxy: String = "http://127.0.0.1:42871", extraPath: Bool = false, httpsPort: UInt16 = 443) -> String {
        let extra = extraPath ? #", "/other":{"Proxy":"http://localhost:3000"}"# : ""
        let json = #"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tailnet.ts.net:443":{"Handlers":{"/":{"Proxy":""# + proxy + #""}"# + extra + #"}}}}"#
        return json.replacingOccurrences(of: "443", with: String(httpsPort))
    }

    private func merged(_ configurations: String...) throws -> String {
        var result: [String: Any] = [:]
        for configuration in configurations {
            let fields = try #require(JSONSerialization.jsonObject(with: Data(configuration.utf8)) as? [String: Any])
            for (key, value) in fields {
                var entries = result[key] as? [String: Any] ?? [:]
                entries.merge(try #require(value as? [String: Any])) { _, new in new }
                result[key] = entries
            }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
    }

    private func expectFailure(_ expected: TailscaleServeSetupError, operation: () async throws -> String) async {
        do {
            _ = try await operation()
            Issue.record("Expected setup failure")
        } catch let error as TailscaleServeSetupError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error type: \(type(of: error))")
        }
    }

    private struct Fixture {
        let directory: URL
        let executable: URL
        var setup: TailscaleServeSetup {
            TailscaleServeSetup(
                detector: TailscaleTailnetOriginDetector(executableCandidates: [executable]),
                commandTimeout: 0.2
            )
        }
        var commands: [String] {
            get throws {
                try String(contentsOf: directory.appendingPathComponent("commands"), encoding: .utf8)
                    .split(separator: "\n").map(String.init)
            }
        }

        init(before: String, after: String? = nil, output: String = "", exitCode: Int = 0, stalls: Bool = false, changesIdentity: Bool = false, changesOnPreflight: String? = nil, changesIdentityBeforeWrite: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("toastty-serve-fixture-\(UUID().uuidString)")
            executable = directory.appendingPathComponent("tailscale")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try before.write(to: directory.appendingPathComponent("status"), atomically: true, encoding: .utf8)
            if let after { try after.write(to: directory.appendingPathComponent("after"), atomically: true, encoding: .utf8) }
            try output.write(to: directory.appendingPathComponent("output"), atomically: true, encoding: .utf8)
            if let changesOnPreflight { try Data(changesOnPreflight.utf8).write(to: directory.appendingPathComponent("preflight-status")) }
            let script = """
            #!/bin/sh
            cd "$(dirname "$0")" || exit 1
            printf '%s\\n' "$*" >> commands
            if [ "$1" = status ]; then
                if [ -f changed-identity ]; then
                    printf '%s\\n' '{"BackendState":"Running","Self":{"DNSName":"mac.tailnet.ts.net.","ID":"node-other"}}'
                else
                    printf '%s\\n' '{"BackendState":"Running","Self":{"DNSName":"mac.tailnet.ts.net.","ID":"node-fixture"}}'
                fi
            elif [ "$2" = status ]; then
                \(changesIdentityBeforeWrite ? ": > changed-identity" : ":")
                if [ -f preflight-status ] && [ -f read-once ]; then /bin/cp preflight-status status; fi
                : > read-once
                /bin/cat status
            else
                if [ -f after ]; then /bin/cp after status; fi
                \(changesIdentity ? ": > changed-identity" : ":")
                /bin/cat output
                \(stalls ? "exec /bin/sleep 30" : "exit \(exitCode)")
            fi
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
