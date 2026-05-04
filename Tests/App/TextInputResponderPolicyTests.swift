import AppKit
@testable import ToasttyApp
import WebKit
import XCTest

@MainActor
final class TextInputResponderPolicyTests: XCTestCase {
    func testTerminalHostViewDoesNotReserveTextInputCommands() {
        XCTAssertFalse(toasttyResponderUsesReservedTextInput(TerminalHostView()))
    }

    func testGenericTextResponderReservesTextInputCommands() {
        XCTAssertTrue(toasttyResponderUsesReservedTextInput(NSTextView()))
    }

    func testWebKitHostedTextResponderStillReservesFindCommands() {
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 240))
        let textView = NSTextView(frame: .init(x: 0, y: 0, width: 120, height: 80))
        webView.addSubview(textView)

        XCTAssertTrue(toasttyResponderUsesReservedTextInput(textView))
    }

    func testWebKitHostedTextResponderDoesNotReserveClosePanelShortcut() {
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 240))
        let textView = NSTextView(frame: .init(x: 0, y: 0, width: 120, height: 80))
        webView.addSubview(textView)

        XCTAssertFalse(toasttyResponderUsesReservedClosePanelShortcut(textView))
    }

    func testBrowserChromeTextFieldDoesNotReserveClosePanelShortcut() {
        XCTAssertFalse(toasttyResponderUsesReservedClosePanelShortcut(BrowserChromeTextField()))
    }

    func testBrowserChromeFieldEditorDoesNotReserveClosePanelShortcut() {
        let textField = BrowserChromeTextField()
        let textView = NSTextView(frame: .init(x: 0, y: 0, width: 120, height: 80))
        textView.delegate = textField

        XCTAssertFalse(toasttyResponderUsesReservedClosePanelShortcut(textView))
    }

    func testLocalDocumentSearchTextFieldDoesNotReserveClosePanelShortcut() {
        XCTAssertFalse(toasttyResponderUsesReservedClosePanelShortcut(LocalDocumentSearchTextField()))
    }

    func testLocalDocumentSearchFieldEditorDoesNotReserveClosePanelShortcut() {
        let textField = LocalDocumentSearchTextField()
        let textView = NSTextView(frame: .init(x: 0, y: 0, width: 120, height: 80))
        textView.delegate = textField

        XCTAssertFalse(toasttyResponderUsesReservedClosePanelShortcut(textView))
    }

    func testNilResponderDoesNotReserveTextInputCommands() {
        XCTAssertFalse(toasttyResponderUsesReservedTextInput(nil))
    }
}
