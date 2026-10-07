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
            #expect(throws: TailscaleServeSetupError.portInUse) { try state(json) }
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
        await expectFailure(.portInUse) {
            try await fixture.setup.run(port: port, configuredOrigin: origin, configureIfNeeded: true)
        }
        await expectFailure(.originMismatch) {
            try await fixture.setup.run(port: port, configuredOrigin: "https://other.tailnet.ts.net", configureIfNeeded: true)
        }
        #expect(try fixture.commands.allSatisfy { !$0.contains("--bg") })
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

    private func state(_ json: String) throws -> TailscaleServeConfigurationState {
        try TailscaleServeSetup.configurationState(from: Data(json.utf8), origin: origin, port: port)
    }

    private func mapping(proxy: String = "http://127.0.0.1:42871", extraPath: Bool = false) -> String {
        let extra = extraPath ? #", "/other":{"Proxy":"http://localhost:3000"}"# : ""
        return #"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tailnet.ts.net:443":{"Handlers":{"/":{"Proxy":""# + proxy + #""}"# + extra + #"}}}}"#
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

        init(before: String, after: String? = nil, output: String = "", exitCode: Int = 0, stalls: Bool = false, changesIdentity: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("toastty-serve-fixture-\(UUID().uuidString)")
            executable = directory.appendingPathComponent("tailscale")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try before.write(to: directory.appendingPathComponent("status"), atomically: true, encoding: .utf8)
            if let after { try after.write(to: directory.appendingPathComponent("after"), atomically: true, encoding: .utf8) }
            try output.write(to: directory.appendingPathComponent("output"), atomically: true, encoding: .utf8)
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
