@testable import ToasttyApp
import XCTest

final class GhosttyDebugLoginShellOverrideTests: XCTestCase {
    func testPlanReturnsNilWithoutOverride() {
        XCTAssertNil(GhosttyDebugLoginShellOverride.plan(environment: [:]))
    }

    func testPlanTrimsShellOverrideAndRequestsTermProgramShimWhenMissing() {
        let plan = GhosttyDebugLoginShellOverride.plan(
            environment: [
                GhosttyDebugLoginShellOverride.environmentKey: "  /usr/local/bin/fish  ",
            ]
        )

        XCTAssertEqual(
            plan,
            GhosttyDebugLoginShellOverridePlan(
                shellPath: "/usr/local/bin/fish",
                requiresTermProgramShim: true
            )
        )
    }

    func testPlanSkipsTermProgramShimWhenAlreadyPresent() {
        let plan = GhosttyDebugLoginShellOverride.plan(
            environment: [
                GhosttyDebugLoginShellOverride.environmentKey: "/usr/local/bin/fish",
                GhosttyDebugLoginShellOverride.termProgramKey: "Apple_Terminal",
            ]
        )

        XCTAssertEqual(
            plan,
            GhosttyDebugLoginShellOverridePlan(
                shellPath: "/usr/local/bin/fish",
                requiresTermProgramShim: false
            )
        )
    }

    func testPlanRejectsBlankShellOverride() {
        XCTAssertNil(
            GhosttyDebugLoginShellOverride.plan(
                environment: [
                    GhosttyDebugLoginShellOverride.environmentKey: "   ",
                ]
            )
        )
    }
}
