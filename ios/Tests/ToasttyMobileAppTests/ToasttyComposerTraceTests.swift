#if DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import ToasttyMobileApp

@MainActor
final class ToasttyComposerTraceTests: XCTestCase {
    func testBufferKeepsNewestEntriesInOrderAndExportDoesNotChangeAfterMoreTyping() throws {
        var uptime: TimeInterval = 100
        let trace = ToasttyComposerTrace(capacity: 3, uptime: { uptime })
        let view = ToasttyComposerUIKitTextView(typingTrace: trace)
        for length in 1...5 {
            uptime += 0.02
            view.text = String(repeating: "x", count: length)
            view.traceTyping(.textChanged)
        }
        let snapshot = trace.snapshot()
        XCTAssertEqual(snapshot.entries.map(\.sequence), [3, 4, 5])
        XCTAssertEqual(snapshot.entries.map(\.textLength), [3, 4, 5])
        XCTAssertEqual(snapshot.droppedEntryCount, 2)
        XCTAssertGreaterThanOrEqual(snapshot.elapsedMillisecondsAtCapture, try XCTUnwrap(snapshot.entries.last).elapsedMilliseconds)
        XCTAssertEqual(snapshot.entries.map(\.elapsedMilliseconds), snapshot.entries.map(\.elapsedMilliseconds).sorted())
        let data = try snapshot.encoded()
        view.text = "later"
        view.traceTyping(.textChanged)
        XCTAssertEqual(try snapshot.encoded(), data)
        XCTAssertEqual(trace.snapshot().entries.map(\.sequence), [4, 5, 6])
    }

    func testActivationRequiresExplicitDiagnosticFlagAndCanBeDisabledAtLaunch() {
        XCTAssertFalse(ToasttyComposerTrace.isEnabled(environment: [:], infoDictionary: [:]))
        XCTAssertFalse(ToasttyComposerTrace.isEnabled(environment: [:], infoDictionary: ["ToasttyComposerTraceEnabled": "NO"]))
        XCTAssertTrue(ToasttyComposerTrace.isEnabled(environment: [:], infoDictionary: ["ToasttyComposerTraceEnabled": "YES"]))
        XCTAssertTrue(ToasttyComposerTrace.isEnabled(environment: ["TOASTTY_MOBILE_COMPOSER_TRACE": "1"], infoDictionary: [:]))
        XCTAssertFalse(ToasttyComposerTrace.isEnabled(environment: ["TOASTTY_MOBILE_COMPOSER_TRACE": "yes"], infoDictionary: [:]))
        XCTAssertFalse(ToasttyComposerTrace.isEnabled(
            environment: ["TOASTTY_MOBILE_COMPOSER_TRACE": "0"], infoDictionary: ["ToasttyComposerTraceEnabled": "YES"]
        ))
        // This test tier uses the normal graph. Disabled capture allocates no shared buffer.
        XCTAssertNil(ToasttyComposerTrace.shared)
        let view = ToasttyComposerUIKitTextView()
        XCTAssertNil(view.typingTrace)
        let parent = ToasttyComposerTextView(
            text: "", onTextChange: { _, _ in }, isFocused: .constant(false),
            placeholder: "Message", isEnabled: true, accessibilityLabel: "Message", accessibilityHint: ""
        )
        XCTAssertFalse(parent.makeCoordinator().responds(to: #selector(UITextViewDelegate.textView(_:shouldChangeTextIn:replacementText:))))
        view.insertText("test")
        view.traceTyping(.textChanged)
        XCTAssertNil(view.typingTrace)
    }

    func testEqualLengthPrivateTextProducesIdenticalEditMetadata() throws {
        func encode(_ text: String) throws -> Data {
            let trace = ToasttyComposerTrace(uptime: { 100 })
            let view = ToasttyComposerUIKitTextView(typingTrace: trace)
            view.insertText(text)
            view.traceTyping(.textChanged)
            return try trace.snapshot(capturedAt: Date(timeIntervalSince1970: 0)).encoded()
        }
        XCTAssertEqual(try encode("PRIVATE-AAAA"), try encode("PRIVATE-BBBB"))
    }

    func testNativeEditsMarkedTextPasteAndAppReplacementExportMetadataOnly() throws {
        let marker = "PRIVATE-DRAFT-7c69"
        let trace = ToasttyComposerTrace()
        let view = ToasttyComposerUIKitTextView(typingTrace: trace)
        let parent = ToasttyComposerTextView(
            text: "", onTextChange: { _, _ in }, isFocused: .constant(true),
            placeholder: marker, isEnabled: true, accessibilityLabel: marker, accessibilityHint: marker
        )
        let coordinator = parent.makeCoordinator()
        view.delegate = coordinator
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        view.frame = CGRect(x: 0, y: 0, width: 280, height: 100)
        host.view.addSubview(view)
        defer { view.resignFirstResponder(); window.isHidden = true }
        XCTAssertTrue(view.becomeFirstResponder())
        view.traceTyping(.created)
        view.insertText(marker)
        // Programmatic UITextInput edits do not send every keyboard delegate
        // callback. Exercise the same delegate path after changing native text.
        coordinator.textViewDidChange(view)
        view.setMarkedText(marker, selectedRange: NSRange(location: marker.utf16.count, length: 0))
        view.traceTyping(.selectionChanged)
        view.unmarkText()
        let range = try XCTUnwrap(view.textRange(from: view.beginningOfDocument, to: view.endOfDocument))
        view.replace(range, withText: marker + " pasted")
        coordinator.textViewDidChange(view)

        // Include arbitrary attributed-string data to catch accidental broad serialization.
        view.textStorage.addAttributes([
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: UIColor.systemOrange,
            NSAttributedString.Key(marker): marker,
        ], range: NSRange(location: 0, length: 3))
        view.typingAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        view.traceTyping(.screenshot)

        let secondView = ToasttyComposerUIKitTextView(typingTrace: trace)
        let secondCoordinator = parent.makeCoordinator()
        secondView.delegate = secondCoordinator
        secondCoordinator.receiveReplacement(.init(revision: 1, expectedEditRevision: 0, text: marker), in: secondView)

        let snapshot = trace.snapshot()
        XCTAssertTrue(snapshot.entries.contains { $0.event == .textChanged && $0.textLength == marker.utf16.count })
        XCTAssertTrue(snapshot.entries.contains { $0.event == .replacementReceived && $0.replacementLength == marker.utf16.count })
        XCTAssertTrue(snapshot.entries.contains { $0.markedRange != nil })
        XCTAssertTrue(snapshot.entries.contains { $0.event == .replacementApplied && $0.textLength == marker.utf16.count })
        XCTAssertEqual(Set(snapshot.entries.map(\.composerID)).count, 2)
        let decoration = try XCTUnwrap(snapshot.decorations.last)
        XCTAssertEqual(decoration.runs.first?.range, .init(NSRange(location: 0, length: 3)))
        XCTAssertEqual(decoration.runs.first?.style, NSUnderlineStyle.single.rawValue)
        XCTAssertTrue(decoration.runs.first?.hasColor == true)
        XCTAssertTrue(decoration.typingHasUnderlineStyle)
        let data = try snapshot.encoded()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(marker))
        try assertMetadataOnly(JSONSerialization.jsonObject(with: data))
    }

    func testScreenshotNotificationRecordsAnchorOnlyForMountedComposer() throws {
        let trace = ToasttyComposerTrace()
        let view = ToasttyComposerUIKitTextView(typingTrace: trace)
        NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        XCTAssertTrue(trace.snapshot().entries.isEmpty)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.addSubview(view)
        defer { window.isHidden = true }
        XCTAssertEqual(UIApplication.shared.applicationState, .active)
        NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        XCTAssertEqual(trace.snapshot().entries.last?.event, .screenshot)
        XCTAssertEqual(trace.snapshot().decorations.last?.sequence, trace.snapshot().entries.last?.sequence)
    }

    func testDecorationCaptureAndInvalidGeometryStayBoundedAndSerializable() throws {
        let trace = ToasttyComposerTrace(capacity: 20)
        let view = ToasttyComposerUIKitTextView(typingTrace: trace)
        view.text = String(repeating: "x", count: 200)
        for index in stride(from: 0, to: 200, by: 2) {
            view.textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: index, length: 1))
        }
        for _ in 0..<20 {
            view.traceTyping(.screenshot, measurement: .init(width: .nan, naturalHeight: .infinity, fittedHeight: 30, maximumHeight: 100))
        }
        let snapshot = trace.snapshot()
        XCTAssertEqual(snapshot.decorations.count, 16)
        XCTAssertEqual(snapshot.decorations.last?.runs.count, 64)
        XCTAssertTrue(snapshot.decorations.last?.runsTruncated == true)
        XCTAssertNil(snapshot.entries.last?.measurement?.width)
        XCTAssertNil(snapshot.entries.last?.measurement?.naturalHeight)
        XCTAssertNoThrow(try snapshot.encoded())
    }

    private func assertMetadataOnly(_ value: Any, key: String? = nil) throws {
        let allowedKeys: Set<String> = [
            "schemaVersion", "capturedAt", "elapsedMillisecondsAtCapture", "appVersion", "appBuild", "operatingSystemVersion", "capacity", "droppedEntryCount",
            "entries", "decorations", "sequence", "elapsedMilliseconds", "composerID", "event", "textLength", "selectedRange",
            "markedRange", "location", "length", "isFirstResponder", "isScrollEnabled", "usesTextKit2",
            "replacementLength", "editRevision", "replacementRevision", "expectedEditRevision", "geometry", "measurement",
            "requestedOffsetY", "width", "height", "contentWidth", "contentHeight", "offsetX", "offsetY", "naturalHeight",
            "fittedHeight", "maximumHeight", "runs", "runsTruncated", "range", "style", "hasStyle", "hasColor", "typingHasUnderlineStyle",
            "typingHasUnderlineColor", "autocorrectionType", "spellCheckingType", "inlinePredictionType", "smartQuotesType",
            "smartDashesType", "smartInsertDeleteType",
        ]
        if let dictionary = value as? [String: Any] {
            XCTAssertTrue(Set(dictionary.keys).isSubset(of: allowedKeys))
            for (key, child) in dictionary { try assertMetadataOnly(child, key: key) }
        } else if let array = value as? [Any] {
            for child in array { try assertMetadataOnly(child, key: key) }
        } else if let string = value as? String {
            if key == "event" {
                XCTAssertNotNil(ToasttyComposerTrace.Event(rawValue: string))
            } else {
                XCTAssertTrue(["capturedAt", "appVersion", "appBuild", "operatingSystemVersion"].contains(key ?? ""))
            }
        } else {
            XCTAssertTrue(value is NSNumber || value is NSNull)
        }
    }
}
#endif
