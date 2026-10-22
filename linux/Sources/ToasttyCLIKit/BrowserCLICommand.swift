import CoreState
import Foundation

/// `toastty browser …` (Linux): drives a Toastty browser panel for testing
/// local apps through the `browser.automation` socket command.
enum BrowserCLICommand {
    static let usage = """
    Usage: toastty [--json] browser <command> [arguments] [--panel <id>] [--workspace <id>] [--timeout <ms>]

    Targets a browser panel in the caller terminal's workspace (or --panel /
    --workspace). Elements are named by a ref from `snapshot` (e12), a CSS
    selector, an XPath (//…), or text=…, role=button[name="Save"], label=…,
    placeholder=…, testid=…, alt=…, title=… (quote the value for an exact
    match: text="Save"). Actions wait up to --timeout (default 10s) for the
    element to be visible, enabled and not covered; --force skips the checks.

    Navigation
      open <url> [--new] [--placement rightPanel|newTab|splitRight]
                               load in the workspace's browser (or a new one); waits for the load
      back | forward | reload  history navigation; waits for the load
      state                    URL, title, navigation state
      list [--all]             browser panels in the workspace (or every workspace)

    Reading
      snapshot [<target>] [--max-lines <n>]
                               accessibility-style outline with element refs
      text [<target>]          rendered text (default: the page)
      html [<target>] [--inner]
      attr <target> <name>     attribute (or value/checked/disabled property)
      count <target>           matching elements (and how many are visible)
      screenshot [--out <file.png>] [--full]
                               PNG of the viewport (or whole page); prints the path
      eval <js> | eval -       evaluate in the page (expression, function, or statements with return)
      console [--errors] [--since <n>] [--clear]
      network [--failed] [--since <n>] [--clear]

    Actions
      click <target> [--right|--middle] [--modifiers Control+Shift] [--force]
      dblclick <target> | hover <target> | focus <target>
      fill <target> <value>    replace a field's value
      type [<target>] <text>   type text key by key (into the focused element without a target)
      press <key>... [--target <target>]
                               Enter, Tab, Escape, ArrowDown, Backspace, Control+a, …
      select <target> <value>...
      check <target> | uncheck <target>
      upload <target> <file>...
      scroll [<target>] [--dx <px>] [--dy <px>]
      dialog accept [<prompt text>] | dialog dismiss
                               how later alert/confirm/prompt dialogs are answered (default: accept)

    Waiting
      wait text <text> | wait text-gone <text> | wait visible <target> | wait hidden <target>
      wait url <substring or *glob*> | wait load | wait idle | wait js <expression>
    """

    struct Parsed {
        var positional: [String] = []
        var flags: [String: String] = [:]
        var switches: Set<String> = []
    }

    static let valueFlags: Set<String> = [
        "--panel", "--workspace", "--window", "--timeout", "--placement", "--max-lines", "--modifiers",
        "--target", "--out", "--since", "--dx", "--dy",
    ]
    static let switchFlags: Set<String> = [
        "--new", "--all", "--force", "--right", "--middle", "--inner", "--full", "--clear", "--errors", "--failed",
    ]

    static func parse(_ arguments: [String]) throws -> Parsed {
        var parsed = Parsed()
        var index = 0
        var literal = false
        while index < arguments.count {
            let argument = arguments[index]
            if literal == false, argument == "--" {
                literal = true
            } else if literal == false, valueFlags.contains(argument) {
                guard index + 1 < arguments.count else { throw ToasttyCLIError.usage("missing value for \(argument)") }
                parsed.flags[argument] = arguments[index + 1]
                index += 1
            } else if literal == false, switchFlags.contains(argument) {
                parsed.switches.insert(argument)
            } else if literal == false, argument.hasPrefix("--"), argument.count > 2, argument != "--" {
                throw ToasttyCLIError.usage("unknown option \(argument) (put arguments that start with -- after a lone --)")
            } else {
                parsed.positional.append(argument)
            }
            index += 1
        }
        return parsed
    }

    static func run(
        arguments: [String],
        options: CLIOptions,
        callerSessionID: String?,
        environment: [String: String]
    ) throws -> Int32 {
        if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") || arguments.first == "help" {
            FileHandle.standardOutput.write(Data((usage + "\n").utf8))
            return arguments.isEmpty ? 64 : 0
        }
        let verb = arguments[0]
        let parsed = try parse(Array(arguments.dropFirst()))
        var payload = try requestPayload(verb: verb, parsed: parsed, environment: environment)
        if payload["verb"] == nil { payload["verb"] = .string(verb) }

        let waitSeconds = parsed.flags["--timeout"].flatMap(Double.init).map { $0 / 1000 } ?? 30
        let client = ToasttySocketClient(socketPath: options.socketPath, timeoutInterval: max(15, waitSeconds + 15))
        let request = AutomationRequestEnvelope(
            requestID: UUID().uuidString,
            command: "browser.automation",
            callerSessionID: callerSessionID,
            payload: payload
        )
        let response = try client.send(request)
        if options.jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(response) + Data("\n".utf8))
            return response.ok ? 0 : 1
        }
        guard response.ok else {
            let message = response.error.map { $0.code == "INVALID_PAYLOAD" ? $0.message : "\($0.code): \($0.message)" } ?? "request failed"
            if response.error?.code == "UNKNOWN_COMMAND" {
                throw ToasttyCLIError.runtime("this Toastty does not support `toastty browser` (update and restart Toastty)")
            }
            throw ToasttyCLIError.runtime("error: \(message)")
        }
        let output = render(verb: verb, result: response.result ?? [:])
        if output.isEmpty == false {
            FileHandle.standardOutput.write(Data((output.hasSuffix("\n") ? output : output + "\n").utf8))
        }
        return 0
    }

    // MARK: Requests

    static func requestPayload(verb: String, parsed: Parsed, environment: [String: String]) throws -> [String: AutomationJSONValue] {
        var payload: [String: AutomationJSONValue] = [:]
        let positional = parsed.positional
        func require(_ count: Int, _ shape: String) throws {
            guard positional.count >= count else { throw ToasttyCLIError.usage("usage: toastty browser \(verb) \(shape)") }
        }
        func integer(_ flag: String) throws -> Int? {
            guard let raw = parsed.flags[flag] else { return nil }
            guard let value = Int(raw) else { throw ToasttyCLIError.usage("\(flag) must be a number") }
            return value
        }

        if let panel = parsed.flags["--panel"] { payload["panelID"] = .string(panel) }
        if let workspace = parsed.flags["--workspace"] { payload["workspaceID"] = .string(workspace) }
        if let window = parsed.flags["--window"] { payload["windowID"] = .string(window) }
        if let panel = environment[ToasttyLaunchContextEnvironment.panelIDKey], panel.isEmpty == false {
            payload["callerPanelID"] = .string(panel)
        }
        if let timeout = try integer("--timeout") { payload["timeoutMs"] = .int(timeout) }
        if parsed.switches.contains("--force") { payload["force"] = .bool(true) }

        switch verb {
        case "list":
            if parsed.switches.contains("--all") { payload["all"] = .bool(true) }
        case "open", "goto", "navigate":
            try require(1, "<url> [--new] [--placement rightPanel|newTab|splitRight]")
            payload["url"] = .string(positional[0])
            if parsed.switches.contains("--new") { payload["newPanel"] = .bool(true) }
            if let placement = parsed.flags["--placement"] { payload["placement"] = .string(placement) }
        case "state", "back", "forward", "reload":
            break
        case "snapshot":
            if let target = positional.first { payload["target"] = .string(target) }
            if let maxLines = try integer("--max-lines") { payload["maxLines"] = .int(maxLines) }
        case "text":
            if let target = positional.first { payload["target"] = .string(target) }
        case "html":
            if let target = positional.first { payload["target"] = .string(target) }
            if parsed.switches.contains("--inner") { payload["inner"] = .bool(true) }
        case "attr":
            try require(2, "<target> <name>")
            payload["target"] = .string(positional[0])
            payload["name"] = .string(positional[1])
        case "count", "hover", "focus", "check", "uncheck":
            try require(1, "<target>")
            payload["target"] = .string(positional[0])
        case "click", "dblclick":
            try require(1, "<target> [--right|--middle] [--modifiers Control+Shift] [--force]")
            payload["target"] = .string(positional[0])
            if parsed.switches.contains("--right") { payload["button"] = .string("right") }
            if parsed.switches.contains("--middle") { payload["button"] = .string("middle") }
            if let modifiers = parsed.flags["--modifiers"] { payload["modifiers"] = modifierList(modifiers) }
        case "fill":
            try require(2, "<target> <value>")
            payload["target"] = .string(positional[0])
            payload["value"] = .string(positional[1])
        case "type":
            try require(1, "[<target>] <text>")
            if positional.count >= 2 {
                payload["target"] = .string(positional[0])
                payload["text"] = .string(positional[1])
            } else {
                payload["text"] = .string(positional[0])
            }
        case "press":
            try require(1, "<key>... [--target <target>]")
            payload["keys"] = .array(positional.map { .string($0) })
            if let target = parsed.flags["--target"] { payload["target"] = .string(target) }
        case "select":
            try require(2, "<target> <value>...")
            payload["target"] = .string(positional[0])
            payload["values"] = .array(positional.dropFirst().map { .string($0) })
        case "upload":
            try require(2, "<target> <file>...")
            payload["target"] = .string(positional[0])
            payload["files"] = .array(positional.dropFirst().map { .string(absolutePath($0)) })
        case "scroll":
            if let target = positional.first { payload["target"] = .string(target) }
            if let dx = try integer("--dx") { payload["dx"] = .int(dx) }
            if let dy = try integer("--dy") { payload["dy"] = .int(dy) }
            if positional.isEmpty, payload["dx"] == nil, payload["dy"] == nil { payload["dy"] = .int(600) }
        case "screenshot":
            if let out = parsed.flags["--out"] ?? positional.first { payload["path"] = .string(absolutePath(out)) }
            if parsed.switches.contains("--full") { payload["fullPage"] = .bool(true) }
        case "eval":
            try require(1, "<js> | eval -")
            if positional[0] == "-" {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                payload["code"] = .string(String(decoding: data, as: UTF8.self))
            } else {
                payload["code"] = .string(positional.joined(separator: " "))
            }
        case "wait":
            try require(1, "text|text-gone|visible|hidden|url|load|idle|js [<value>] [--timeout <ms>]")
            let kind = positional[0]
            payload["kind"] = .string(kind)
            if ["text", "text-gone", "visible", "hidden", "url", "js"].contains(kind) {
                try require(2, "\(kind) <value>")
                payload["value"] = .string(positional.dropFirst().joined(separator: " "))
            }
        case "console", "network":
            if let since = try integer("--since") { payload["since"] = .int(since) }
            if parsed.switches.contains("--clear") { payload["clear"] = .bool(true) }
            if parsed.switches.contains("--errors") { payload["errorsOnly"] = .bool(true) }
            if parsed.switches.contains("--failed") { payload["failedOnly"] = .bool(true) }
        case "dialog":
            try require(1, "accept [<prompt text>] | dismiss")
            switch positional[0] {
            case "accept":
                payload["accept"] = .bool(true)
                if positional.count > 1 { payload["promptText"] = .string(positional.dropFirst().joined(separator: " ")) }
            case "dismiss":
                payload["accept"] = .bool(false)
            default:
                throw ToasttyCLIError.usage("usage: toastty browser dialog accept [<prompt text>] | dismiss")
            }
        default:
            throw ToasttyCLIError.usage("unknown browser command: \(verb)\n\n\(usage)")
        }
        if verb == "goto" || verb == "navigate" { payload["verb"] = .string("open") }
        return payload
    }

    static func modifierList(_ raw: String) -> AutomationJSONValue {
        .array(raw.split(separator: "+").map { .string(String($0)) })
    }

    static func absolutePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).standardizedFileURL.path
    }

    // MARK: Output

    static func render(verb: String, result: [String: AutomationJSONValue]) -> String {
        func string(_ key: String) -> String? { result.string(key) }
        switch verb {
        case "list":
            guard case .array(let panels)? = result["panels"], panels.isEmpty == false else { return "no browser panels" }
            return panels.compactMap { value -> String? in
                guard case .object(let panel) = value else { return nil }
                let title = panel.string("title") ?? ""
                let url = panel.string("url") ?? "(start page)"
                let workspace = panel.string("workspaceTitle").map { "  [\($0)]" } ?? ""
                return "\(panel.string("panelID") ?? "?")  \(url)  \"\(title)\"\(workspace)"
            }.joined(separator: "\n")
        case "open", "goto", "navigate", "state", "back", "forward", "reload":
            var line = "\(string("navigationState") ?? "?")  \(string("observedURL") ?? string("stateRestorableURL") ?? "(no page)")"
            if let title = string("title"), title.isEmpty == false { line += "  \"\(title)\"" }
            if case .object(let error)? = result["navigationError"] { line += "\nerror: \(error.string("message") ?? "load failed")" }
            line += "\npanel \(string("panelID") ?? "?")" + (result.bool("created") == true ? " (new)" : "")
            return line
        case "snapshot":
            var text = string("snapshot") ?? ""
            if text.isEmpty { text = "(nothing visible)" }
            let header = "# \(string("title") ?? "") — \(string("url") ?? "")"
            return header + "\n" + text + (result.bool("truncated") == true ? "\n… (truncated; pass a target or --max-lines)" : "")
        case "text":
            return string("text") ?? ""
        case "html":
            return string("html") ?? ""
        case "attr":
            return result["value"].map(plainText) ?? "null"
        case "count":
            return "\(result.int("count") ?? 0) (\(result.int("visible") ?? 0) visible)"
        case "eval":
            return result["value"].map(plainText) ?? "undefined"
        case "wait":
            return "ok after \(result.int("elapsedMs") ?? 0)ms"
        case "screenshot":
            let size = result.int("width").map { w in " (\(w)x\(result.int("height") ?? 0))" } ?? ""
            return (string("path") ?? "") + size
        case "dialog":
            return result.bool("accept") == true ? "dialogs will be accepted" : "dialogs will be dismissed"
        case "console":
            guard case .array(let entries)? = result["entries"] else { return "" }
            let lines = entries.compactMap { value -> String? in
                guard case .object(let entry) = value else { return nil }
                return "#\(entry.int("sequence") ?? 0) [\(entry.string("level") ?? "log")] \(entry.string("text") ?? "")"
            }
            return lines.isEmpty ? "(no console messages)" : lines.joined(separator: "\n")
        case "network":
            guard case .array(let entries)? = result["entries"] else { return "" }
            let lines = entries.compactMap { value -> String? in
                guard case .object(let entry) = value else { return nil }
                let status: String
                if let error = entry.string("error") { status = "ERR \(error)" }
                else if let code = entry.int("status") { status = String(code) }
                else { status = entry.bool("finished") == true ? "done" : "…" }
                let duration = entry.int("durationMs").map { " \($0)ms" } ?? ""
                return "#\(entry.int("sequence") ?? 0) \(status) \(entry.string("method") ?? "GET") \(entry.string("url") ?? "")\(duration)"
            }
            return lines.isEmpty ? "(no requests)" : lines.joined(separator: "\n")
        default:
            var line = actionPastTense(verb)
            if let element = string("element") { line += " " + element }
            if let value = result["value"], verb == "fill" || verb == "type" { line += " → " + plainText(value) }
            if case .array(let values)? = result["values"] { line += " → " + values.map(plainText).joined(separator: ", ") }
            if case .array(let files)? = result["files"] { line += " ← " + files.map(plainText).joined(separator: ", ") }
            if result.bool("changed") == false { line += " (already \(verb == "check" ? "checked" : "unchecked"))" }
            if let matches = result.int("matches"), matches > 1 { line += "  (\(matches) matches; used the first visible)" }
            if result.bool("navigated") == true { line += "\nnavigated to \(string("url") ?? "?")" }
            return line
        }
    }

    static func actionPastTense(_ verb: String) -> String {
        switch verb {
        case "click": return "clicked"
        case "dblclick": return "double-clicked"
        case "hover": return "hovered"
        case "focus": return "focused"
        case "fill": return "filled"
        case "type": return "typed into"
        case "press": return "pressed keys on"
        case "select": return "selected in"
        case "check": return "checked"
        case "uncheck": return "unchecked"
        case "upload": return "uploaded to"
        case "scroll": return "scrolled"
        default: return verb
        }
    }

    static func plainText(_ value: AutomationJSONValue) -> String {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .null: return "null"
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }
}
