import CoreState
import Foundation
import Testing
@testable import ToasttyAppLogic

/// `toastty browser` helpers that do not need a web view (the Broadway
/// test in ToasttyLinuxPanelsTests drives the page library end to end).
@MainActor
struct LinuxBrowserAutomationTests {
    @Test func urlPatterns() {
        #expect(LinuxBrowserAutomation.urlMatches("http://localhost:3000/todos?x=1", pattern: "/todos"))
        #expect(LinuxBrowserAutomation.urlMatches("http://localhost:3000/todos", pattern: "*/todos"))
        #expect(LinuxBrowserAutomation.urlMatches("http://localhost:3000/todos/7", pattern: "http://*/todos/*"))
        #expect(LinuxBrowserAutomation.urlMatches("http://localhost:3000/todos/7", pattern: "*/todos") == false)
        #expect(LinuxBrowserAutomation.urlMatches(nil, pattern: "x") == false)
    }

    @Test func pageResultsKeepBooleansAndNumbersApart() {
        let object = LinuxBrowserAutomation.jsonObject(#"{"ok":true,"n":1,"z":0,"f":1.5,"s":"x","a":[false,2],"o":null}"#)
        #expect(object?["ok"] == .bool(true))
        #expect(object?["n"] == .int(1))
        #expect(object?["z"] == .int(0))
        #expect(object?["f"] == .double(1.5))
        #expect(object?["a"] == .array([.bool(false), .int(2)]))
        #expect(object?["o"] == .null)
    }

    @Test func libraryArgumentsDropRoutingKeys() throws {
        let args = LinuxBrowserAutomation.plainArguments([
            "verb": .string("fill"), "panelID": .string("P"), "callerPanelID": .string("C"), "timeoutMs": .int(5),
            "target": .string("#q"), "value": .string("v"), "force": .bool(true),
        ])
        #expect(Set(args.keys) == ["target", "value", "force"])
        let body = try LinuxBrowserAutomationScript.body(command: ["op": "fill", "target": "#q\"); alert(1); (\""])
        // The command is embedded as JSON, never as code.
        #expect(body.contains(#"tta.run({"#))
        #expect(body.contains(#"#q\"); alert(1); (\""#))
    }

    @Test func pngDimensionsAndUploads() throws {
        var header = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        header.append(contentsOf: [0, 0, 0x05, 0x00, 0, 0, 0x02, 0xD0])
        #expect(LinuxBrowserAutomation.pngSize(header)! == (1280, 720))

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let files = try LinuxBrowserAutomation.uploadFiles([file.path])
        #expect(files.first?["type"] as? String == "application/json")
        #expect(files.first?["base64"] as? String == "e30=")
        #expect(throws: (any Error).self) { try LinuxBrowserAutomation.uploadFiles(["/nonexistent/file"]) }
    }
}
