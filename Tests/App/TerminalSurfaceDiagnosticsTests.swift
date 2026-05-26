#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import XCTest

@MainActor
final class TerminalSurfaceDiagnosticsTests: XCTestCase {
    func testIsEnabledFlagAcceptsCommonTruthyValues() {
        XCTAssertTrue(TerminalSurfaceDiagnostics.isEnabledFlag("1"))
        XCTAssertTrue(TerminalSurfaceDiagnostics.isEnabledFlag(" true "))
        XCTAssertTrue(TerminalSurfaceDiagnostics.isEnabledFlag("YES"))
        XCTAssertTrue(TerminalSurfaceDiagnostics.isEnabledFlag("on"))

        XCTAssertFalse(TerminalSurfaceDiagnostics.isEnabledFlag(nil))
        XCTAssertFalse(TerminalSurfaceDiagnostics.isEnabledFlag(""))
        XCTAssertFalse(TerminalSurfaceDiagnostics.isEnabledFlag("0"))
        XCTAssertFalse(TerminalSurfaceDiagnostics.isEnabledFlag("false"))
    }
}
#endif
