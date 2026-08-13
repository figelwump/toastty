import Foundation
import Testing
@testable import ToasttyApp

struct TailscaleTailnetOriginDetectorTests {
    @Test func decodesCanonicalOriginFromTolerantStatusJSON() throws {
        let data = Data(#"""
        {
            "BackendState":"Running",
            "Self":{"DNSName":"MAC.TAILNET.TS.NET.","Unknown":true},
            "FutureField":{"value":1}
        }
        """#.utf8)

        #expect(try TailscaleTailnetOriginDetector.origin(fromStatusJSON: data) == "https://mac.tailnet.ts.net")
    }

    @Test func reportsActionableBackendStates() {
        assertDetectionError(
            .needsLogin,
            json: #"{"BackendState":"NeedsLogin","Self":{"DNSName":"mac.tailnet.ts.net."}}"#
        )
        assertDetectionError(
            .notRunning,
            json: #"{"BackendState":"Stopped","Self":{"DNSName":"mac.tailnet.ts.net."}}"#
        )
        assertDetectionError(
            .needsMachineApproval,
            json: #"{"BackendState":"NeedsMachineAuth","Self":{"DNSName":"mac.tailnet.ts.net."}}"#
        )
        assertDetectionError(
            .unavailable,
            json: #"{"Self":{"DNSName":"mac.tailnet.ts.net."}}"#
        )
    }

    @Test func rejectsMissingOrUnsupportedDNSNames() {
        assertDetectionError(
            .unavailable,
            json: #"{"BackendState":"Running","Self":{}}"#
        )
        assertDetectionError(
            .invalidOrigin,
            json: #"{"BackendState":"Running","Self":{"DNSName":"mac.example.com."}}"#
        )
    }

    @Test func fallsThroughToAUsableTailscaleClient() async throws {
        let first = URL(fileURLWithPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        let second = URL(fileURLWithPath: "/opt/homebrew/bin/tailscale")
        let detector = TailscaleTailnetOriginDetector(
            executableCandidates: [first, second],
            timeout: 1,
            commandRunner: { executableURL, arguments, _ in
                guard arguments == ["status", "--json", "--peers=false"] else {
                    throw TailscaleTailnetOriginDetectionError.unavailable
                }
                if executableURL == first {
                    return Data(#"{"BackendState":"NeedsLogin"}"#.utf8)
                }
                return Data(#"{"BackendState":"Running","Self":{"DNSName":"mac.tailnet.ts.net."}}"#.utf8)
            },
            isExecutable: { _ in true }
        )

        #expect(try await detector.detectOrigin() == "https://mac.tailnet.ts.net")
    }

    @Test func preservesActionableErrorWhenALaterClientTimesOut() async {
        let first = URL(fileURLWithPath: "/first/tailscale")
        let second = URL(fileURLWithPath: "/second/tailscale")
        let detector = TailscaleTailnetOriginDetector(
            executableCandidates: [first, second],
            timeout: 1,
            commandRunner: { executableURL, _, _ in
                if executableURL == first {
                    return Data(#"{"BackendState":"NeedsLogin"}"#.utf8)
                }
                throw TailscaleStatusCommandRunnerError.timedOut
            },
            isExecutable: { _ in true }
        )

        await assertDetectionError(.needsLogin) {
            try await detector.detectOrigin()
        }
    }

    @Test func reportsMissingExecutable() async {
        let detector = TailscaleTailnetOriginDetector(
            executableCandidates: [URL(fileURLWithPath: "/missing/tailscale")],
            commandRunner: { _, _, _ in Data() },
            isExecutable: { _ in false }
        )

        await assertDetectionError(.notInstalled) {
            try await detector.detectOrigin()
        }
    }

    @Test func preservesParentEnvironmentAndForcesCLIMode() {
        let environment = TailscaleStatusCommandRunner.environment(
            merging: ["HOME": "/Users/example", "TAILSCALE_BE_CLI": "0"]
        )

        #expect(environment["HOME"] == "/Users/example")
        #expect(environment["TAILSCALE_BE_CLI"] == "1")
    }

    @Test func processRunnerTimesOutAndReapsCommand() async {
        do {
            _ = try await TailscaleStatusCommandRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["1"],
                timeout: 0.05
            )
            Issue.record("Expected the command to time out")
        } catch let error as TailscaleStatusCommandRunnerError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func cancellingParentTaskStopsAndReapsCommandPromptly() async {
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            try await TailscaleStatusCommandRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 5
            )
        }

        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(start.duration(to: clock.now) < .seconds(1))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func automaticDetectionNeverOverwritesUserInput() {
        #expect(TailnetOriginDetectionPolicy.shouldApply(
            originAtStart: "",
            currentOrigin: "",
            allowsReplacingExistingOrigin: false
        ))
        #expect(TailnetOriginDetectionPolicy.shouldApply(
            originAtStart: "",
            currentOrigin: "https://typed.tailnet.ts.net",
            allowsReplacingExistingOrigin: false
        ) == false)
        #expect(TailnetOriginDetectionPolicy.shouldApply(
            originAtStart: "https://saved.tailnet.ts.net",
            currentOrigin: "https://saved.tailnet.ts.net",
            allowsReplacingExistingOrigin: false
        ) == false)
    }

    @Test func explicitDetectionReplacesOnlyAnUnchangedValue() {
        #expect(TailnetOriginDetectionPolicy.shouldApply(
            originAtStart: "https://saved.tailnet.ts.net",
            currentOrigin: "https://saved.tailnet.ts.net",
            allowsReplacingExistingOrigin: true
        ))
        #expect(TailnetOriginDetectionPolicy.shouldApply(
            originAtStart: "https://saved.tailnet.ts.net",
            currentOrigin: "https://typed.tailnet.ts.net",
            allowsReplacingExistingOrigin: true
        ) == false)
    }

    private func assertDetectionError(
        _ expected: TailscaleTailnetOriginDetectionError,
        json: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try TailscaleTailnetOriginDetector.origin(fromStatusJSON: Data(json.utf8))
            Issue.record("Expected detection to fail", sourceLocation: sourceLocation)
        } catch let error as TailscaleTailnetOriginDetectionError {
            #expect(error == expected, sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }

    private func assertDetectionError(
        _ expected: TailscaleTailnetOriginDetectionError,
        sourceLocation: SourceLocation = #_sourceLocation,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected detection to fail", sourceLocation: sourceLocation)
        } catch let error as TailscaleTailnetOriginDetectionError {
            #expect(error == expected, sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }
}
