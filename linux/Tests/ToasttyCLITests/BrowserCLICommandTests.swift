import CoreState
import Foundation
import Testing
@testable import ToasttyCLIKit

/// `toastty browser` argument parsing and output (Linux only).
struct BrowserCLICommandTests {
    func payload(_ arguments: [String], environment: [String: String] = [:]) throws -> [String: AutomationJSONValue] {
        let parsed = try BrowserCLICommand.parse(Array(arguments.dropFirst()))
        return try BrowserCLICommand.requestPayload(verb: arguments[0], parsed: parsed, environment: environment)
    }

    @Test func routesTargetsAndCallerPanel() throws {
        let fill = try payload(["fill", "label=Email", "a@b.c", "--panel", "P1", "--timeout", "2500"], environment: ["TOASTTY_PANEL_ID": "CALLER"])
        #expect(fill["target"] == .string("label=Email"))
        #expect(fill["value"] == .string("a@b.c"))
        #expect(fill["panelID"] == .string("P1"))
        #expect(fill["timeoutMs"] == .int(2500))
        #expect(fill["callerPanelID"] == .string("CALLER"))

        let typed = try payload(["type", "hello"])
        #expect(typed["target"] == nil && typed["text"] == .string("hello"))
        let press = try payload(["press", "Control+a", "Backspace", "--target", "#q"])
        #expect(press["keys"] == .array([.string("Control+a"), .string("Backspace")]))
        #expect(press["target"] == .string("#q"))
        let click = try payload(["click", "e12", "--right", "--modifiers", "Control+Shift", "--force"])
        #expect(click["button"] == .string("right"))
        #expect(click["modifiers"] == .array([.string("Control"), .string("Shift")]))
        #expect(click["force"] == .bool(true))
    }

    @Test func waitOpenDialogAndPaths() throws {
        let wait = try payload(["wait", "text", "Saved", "changes"])
        #expect(wait["kind"] == .string("text") && wait["value"] == .string("Saved changes"))
        #expect(try payload(["wait", "load"])["value"] == nil)
        #expect(throws: ToasttyCLIError.self) { try payload(["wait", "visible"]) }

        let open = try payload(["goto", "localhost:3000", "--new", "--placement", "splitRight"])
        #expect(open["verb"] == .string("open"))
        #expect(open["url"] == .string("localhost:3000") && open["newPanel"] == .bool(true))
        #expect(open["placement"] == .string("splitRight"))

        let prompt = try payload(["dialog", "accept", "Jane", "Doe"])
        #expect(prompt["accept"] == .bool(true) && prompt["promptText"] == .string("Jane Doe"))
        #expect(try payload(["dialog", "dismiss"])["accept"] == .bool(false))

        let shot = try payload(["screenshot", "--out", "shots/a.png", "--full"])
        guard case .string(let path)? = shot["path"] else { Issue.record("no path"); return }
        #expect(path.hasPrefix("/") && path.hasSuffix("/shots/a.png"))
        #expect(shot["fullPage"] == .bool(true))
    }

    @Test func rejectsUnknownOptionsButPassesThemAfterDoubleDash() throws {
        #expect(throws: ToasttyCLIError.self) { try payload(["fill", "#q", "--bogus"]) }
        #expect(try payload(["fill", "#q", "--", "--literal"])["value"] == .string("--literal"))
        #expect(throws: ToasttyCLIError.self) { try payload(["frobnicate"]) }
    }

    @Test func rendersActionsAndLogs() {
        #expect(BrowserCLICommand.render(verb: "click", result: [
            "element": .string("button \"Save\""), "matches": .int(3), "navigated": .bool(true), "url": .string("http://x/next"),
        ]) == "clicked button \"Save\"  (3 matches; used the first visible)\nnavigated to http://x/next")
        #expect(BrowserCLICommand.render(verb: "network", result: ["entries": .array([
            .object(["sequence": .int(4), "method": .string("GET"), "url": .string("http://x/a.json"), "status": .int(404), "durationMs": .int(12), "finished": .bool(true)]),
        ])]) == "#4 404 GET http://x/a.json 12ms")
        #expect(BrowserCLICommand.render(verb: "eval", result: ["value": .int(42)]) == "42")
    }
}
