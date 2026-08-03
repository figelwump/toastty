import XCTest

final class GhosttyCoverageCanaryTests: XCTestCase {
    func testGhosttyBackedCoverageIsEnabledOrFallbackWasExplicitlyRequested() {
        #if TOASTTY_HAS_GHOSTTY_KIT || TOASTTY_EXPLICIT_GHOSTTY_TEST_FALLBACK
        let coverageContractIsSatisfied = true
        #else
        let coverageContractIsSatisfied = false
        #endif

        XCTAssertTrue(
            coverageContractIsSatisfied,
            "Ghostty-backed terminal tests were compiled out without an explicit fallback request. Regenerate with Ghostty, or set TUIST_DISABLE_GHOSTTY=1 for an intentional fallback test run."
        )
    }
}
