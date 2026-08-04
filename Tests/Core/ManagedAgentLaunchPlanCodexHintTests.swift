import XCTest
@testable import CoreState

final class ManagedAgentLaunchPlanCodexHintTests: XCTestCase {
    func testOlderRequestWithoutCodexHintStillDecodes() throws {
        let data = Data(
            #"""
            {
              "agent":"codex",
              "panelID":"00000000-0000-0000-0000-000000000001",
              "argv":["codex"],
              "cwd":"/tmp",
              "environment":{},
              "preflightPolicy":"skip"
            }
            """#.utf8
        )

        let request = try JSONDecoder().decode(ManagedAgentLaunchRequest.self, from: data)

        XCTAssertNil(request.codexCapabilityHint)
    }

    func testCodexCapabilityHintRoundTrips() throws {
        let request = ManagedAgentLaunchRequest(
            agent: .codex,
            panelID: UUID(),
            argv: ["codex", "resume"],
            cwd: "/tmp",
            codexCapabilityHint: ManagedCodexCapabilityHint(
                resolvedExecutablePath: "/opt/codex/bin/codex",
                codexHomePath: "/tmp/isolated codex home",
                processPath: "/opt/codex/bin:/usr/bin:/bin"
            )
        )

        let decoded = try JSONDecoder().decode(
            ManagedAgentLaunchRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
    }

    func testOlderCodexCapabilityHintWithoutProcessPathStillDecodes() throws {
        let data = Data(
            #"""
            {
              "agent":"codex",
              "panelID":"00000000-0000-0000-0000-000000000001",
              "argv":["codex"],
              "cwd":"/tmp",
              "environment":{},
              "preflightPolicy":"skip",
              "codexCapabilityHint":{
                "resolvedExecutablePath":"/opt/codex/bin/codex",
                "codexHomePath":"/tmp/codex-home"
              }
            }
            """#.utf8
        )

        let request = try JSONDecoder().decode(ManagedAgentLaunchRequest.self, from: data)

        XCTAssertEqual(request.codexCapabilityHint?.resolvedExecutablePath, "/opt/codex/bin/codex")
        XCTAssertEqual(request.codexCapabilityHint?.codexHomePath, "/tmp/codex-home")
        XCTAssertNil(request.codexCapabilityHint?.processPath)
    }
}
