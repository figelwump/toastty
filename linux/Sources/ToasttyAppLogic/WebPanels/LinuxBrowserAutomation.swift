import CoreState
import Foundation

/// Page access the browser frontend gives `toastty browser`
/// (`BrowserPanelController` on Linux).
@MainActor
public protocol LinuxBrowserAutomationHost: AnyObject {
    /// Runs `body` as the body of an async function in `world` (nil: the
    /// page's main world). Returns a string result as is and any other
    /// result as JSON; nil for undefined/null.
    func callAutomationFunction(_ body: String, world: String?) async throws -> String?
    /// PNG of the visible viewport, or of the whole document.
    func captureAutomationScreenshotPNG(fullPage: Bool) async throws -> Data
    /// Console messages, uncaught errors and answered dialogs, oldest first.
    var automationConsole: [LinuxBrowserConsoleEntry] { get }
    func clearAutomationConsole()
    /// Resource loads (main frame, subresources, fetch/XHR), oldest first.
    var automationNetwork: [LinuxBrowserNetworkEntry] { get }
    var automationRequestsInFlight: Int { get }
    func clearAutomationNetwork()
    /// Once set, JavaScript dialogs are answered by this policy without UI.
    var automationDialogPolicy: LinuxBrowserDialogPolicy? { get set }
}

public struct LinuxBrowserConsoleEntry: Equatable, Sendable {
    public let sequence: Int
    /// `log`, `info`, `warn`, `error`, `debug`, `pageerror`, or `dialog`.
    public let level: String
    public let text: String
    public let url: String?
    public let date: Date

    public init(sequence: Int, level: String, text: String, url: String?, date: Date) {
        self.sequence = sequence
        self.level = level
        self.text = text
        self.url = url
        self.date = date
    }
}

public struct LinuxBrowserNetworkEntry: Equatable, Sendable {
    public let sequence: Int
    public let method: String
    public let url: String
    public var status: Int?
    public var mimeType: String?
    public var error: String?
    public var isFinished: Bool
    public let startedAt: Date
    public var finishedAt: Date?

    public init(sequence: Int, method: String, url: String, startedAt: Date) {
        self.sequence = sequence
        self.method = method
        self.url = url
        self.startedAt = startedAt
        isFinished = false
    }
}

public struct LinuxBrowserDialogPolicy: Equatable, Sendable {
    public var accept: Bool
    public var promptText: String?

    public init(accept: Bool, promptText: String?) {
        self.accept = accept
        self.promptText = promptText
    }
}

/// `browser.automation` socket command (`toastty browser …`): Playwright-like
/// control of a browser panel for testing local apps. Elements are found by
/// snapshot ref (`e12`), CSS, XPath, or `text=`/`role=`/`label=`/
/// `placeholder=`/`testid=` locators; input is synthetic DOM events.
@MainActor
struct LinuxBrowserAutomation {
    let executor: AppControlExecutor
    let registry: WebPanelRuntimeRegistry
    let context: AutomationRequestContext

    static let defaultActionTimeout: TimeInterval = 10
    static let defaultNavigationTimeout: TimeInterval = 30
    static let maximumUploadBytes = 64 << 20

    struct Target {
        let workspaceID: UUID
        let panelID: UUID
        let webState: WebPanelState
        let runtime: BrowserPanelRuntime
    }

    func run(_ payload: [String: AutomationJSONValue]) async throws -> [String: AutomationJSONValue] {
        guard let verb = payload.string("verb") else {
            throw AutomationSocketError.invalidPayload("verb is required")
        }
        switch verb {
        case "list":
            return try list(payload)
        case "open":
            return try await open(payload)
        default:
            break
        }

        let target = try resolve(payload)
        let timeout = Self.timeout(payload, default: Self.defaultActionTimeout)
        switch verb {
        case "state":
            return state(target)
        case "back", "forward", "reload":
            let before = target.runtime.navigationGeneration
            let started: Bool
            switch verb {
            case "back": started = target.runtime.goBack()
            case "forward": started = target.runtime.goForward()
            default: started = target.runtime.reload(webState: target.webState)
            }
            guard started else { throw AutomationSocketError.invalidPayload("cannot go \(verb) in this browser") }
            await waitForNavigation(target.runtime, after: before, startGrace: 1, timeout: Self.timeout(payload, default: Self.defaultNavigationTimeout))
            return state(target)
        case "dialog":
            let host = try automationHost(target)
            host.automationDialogPolicy = LinuxBrowserDialogPolicy(
                accept: payload.bool("accept") ?? true,
                promptText: payload.string("promptText")
            )
            return ["panelID": .string(target.panelID.uuidString), "accept": .bool(payload.bool("accept") ?? true)]
        case "console":
            return console(target, payload)
        case "network":
            return network(target, payload)
        case "screenshot":
            return try await screenshot(target, payload)
        case "eval":
            return try await evaluate(target, payload)
        case "wait":
            return try await wait(target, payload, timeout: Self.timeout(payload, default: Self.defaultNavigationTimeout))
        case "snapshot", "text", "html", "attr", "count":
            var args = Self.plainArguments(payload)
            args["op"] = verb == "attr" ? "attribute" : verb
            let result = try await page(target, args, timeout: verb == "count" ? 0 : timeout)
            return result.merging(["panelID": .string(target.panelID.uuidString)]) { current, _ in current }
        case "click", "dblclick", "hover", "focus", "fill", "type", "press", "select", "check", "uncheck", "scroll", "upload":
            return try await act(verb, target, payload, timeout: timeout)
        default:
            throw AutomationSocketError.invalidPayload("unknown browser command: \(verb)")
        }
    }

    // MARK: Targets

    private func store() throws -> AppStore { try executor.requiredStore() }

    /// The explicit panel, else a browser in the explicit workspace, else
    /// one in the caller terminal's workspace (`TOASTTY_PANEL_ID`), else in
    /// the selected workspace; the same preference order as
    /// `panel.browser.state`.
    private func resolve(_ payload: [String: AutomationJSONValue]) throws -> Target {
        let args = try selectorArguments(payload)
        let resolved = try executor.linuxBrowserTarget(args: args, context: context)
        let runtime = registry.browserRuntime(for: resolved.panelID)
        runtime.apply(webState: resolved.webState)
        return Target(workspaceID: resolved.workspaceID, panelID: resolved.panelID, webState: resolved.webState, runtime: runtime)
    }

    private func selectorArguments(_ payload: [String: AutomationJSONValue]) throws -> [String: AutomationJSONValue] {
        var args: [String: AutomationJSONValue] = [:]
        for key in ["panelID", "workspaceID", "windowID"] { args[key] = payload[key] }
        if args.isEmpty, let caller = payload.uuid("callerPanelID"),
           let selection = try store().state.workspaceSelection(containingPanelID: caller) {
            args["workspaceID"] = .string(selection.workspaceID.uuidString)
        }
        return args
    }

    private func browserPanels(in workspaceID: UUID) throws -> [(panelID: UUID, webState: WebPanelState)] {
        guard let workspace = try store().state.workspacesByID[workspaceID] else { return [] }
        return workspace.allPanelsByID.compactMap { panelID, panel in
            guard case .web(let webState) = panel, webState.definition == .browser else { return nil }
            return (panelID, webState)
        }.sorted { $0.panelID.uuidString < $1.panelID.uuidString }
    }

    private func automationHost(_ target: Target) throws -> any LinuxBrowserAutomationHost {
        guard let host = target.runtime.automationHost() else {
            throw AutomationSocketError.invalidPayload("the browser panel has no web view")
        }
        // Dialogs would block the page (and every later command) until a
        // person answered them.
        if host.automationDialogPolicy == nil {
            host.automationDialogPolicy = LinuxBrowserDialogPolicy(accept: true, promptText: nil)
        }
        return host
    }

    // MARK: Navigation

    private func list(_ payload: [String: AutomationJSONValue]) throws -> [String: AutomationJSONValue] {
        let state = try store().state
        let workspaceIDs: [UUID]
        if payload.bool("all") == true {
            workspaceIDs = state.windows.flatMap(\.workspaceIDs)
        } else {
            let args = try selectorArguments(payload)
            if let panelID = args.uuid("panelID"), let selection = state.workspaceSelection(containingPanelID: panelID) {
                workspaceIDs = [selection.workspaceID]
            } else {
                workspaceIDs = [try executor.linuxBrowserWorkspaceID(args: args, context: context)]
            }
        }
        var panels: [AutomationJSONValue] = []
        for workspaceID in workspaceIDs {
            let title = state.workspacesByID[workspaceID]?.title
            for (panelID, webState) in try browserPanels(in: workspaceID) {
                let runtimeState = registry.browserRuntime(for: panelID).automationState()
                panels.append(.object([
                    "panelID": .string(panelID.uuidString),
                    "workspaceID": .string(workspaceID.uuidString),
                    "workspaceTitle": title.map { .string($0) } ?? .null,
                    "url": (runtimeState.observedURL ?? webState.restorableURL).map { .string($0) } ?? .null,
                    "title": .string(runtimeState.title ?? webState.title),
                ]))
            }
        }
        return ["panels": .array(panels)]
    }

    /// Navigates the target browser, or creates one (`--new`, or when the
    /// workspace has none), and waits for the load to settle.
    private func open(_ payload: [String: AutomationJSONValue]) async throws -> [String: AutomationJSONValue] {
        guard let rawURL = payload.string("url"),
              let url = BrowserPanelRuntime.normalizedUserEnteredURLString(rawURL) else {
            throw AutomationSocketError.invalidPayload("url is required")
        }
        let timeout = Self.timeout(payload, default: Self.defaultNavigationTimeout)
        let existing: Target? = payload.bool("newPanel") == true ? nil : (try? resolve(payload))
        if let existing {
            let before = existing.runtime.navigationGeneration
            guard existing.runtime.loadForAutomation(urlString: url) else {
                throw AutomationSocketError.invalidPayload("could not load \(url)")
            }
            await waitForNavigation(existing.runtime, after: before, startGrace: 2, timeout: timeout)
            return state(existing).merging(["created": .bool(false)]) { current, _ in current }
        }

        let args = try selectorArguments(payload)
        let workspaceID: UUID
        if let panelID = args.uuid("panelID"), let selection = try store().state.workspaceSelection(containingPanelID: panelID) {
            workspaceID = selection.workspaceID
        } else {
            workspaceID = try executor.linuxBrowserWorkspaceID(args: args, context: context)
        }
        let before = Set(try browserPanels(in: workspaceID).map(\.panelID))
        let placement: WebPanelPlacement? = try payload.string("placement").map { try executor.linuxBrowserPlacement($0) }
        guard try store().createBrowserPanel(
            workspaceID: workspaceID,
            request: BrowserPanelCreateRequest(initialURL: url, placementOverride: placement)
        ) else {
            throw AutomationSocketError.invalidPayload("could not create a browser panel")
        }
        guard let created = try browserPanels(in: workspaceID).first(where: { before.contains($0.panelID) == false }) else {
            throw AutomationSocketError.internalError("the new browser panel was not found")
        }
        let runtime = registry.browserRuntime(for: created.panelID)
        let generation = runtime.navigationGeneration
        runtime.apply(webState: created.webState)
        let target = Target(workspaceID: workspaceID, panelID: created.panelID, webState: created.webState, runtime: runtime)
        await waitForNavigation(runtime, after: generation, startGrace: 2, timeout: timeout)
        return state(target).merging(["created": .bool(true)]) { current, _ in current }
    }

    /// Waits for a navigation after `generation` to start (within
    /// `startGrace` seconds) and then to finish or fail. Returns whether one
    /// started.
    @discardableResult
    private func waitForNavigation(_ runtime: BrowserPanelRuntime, after generation: Int, startGrace: TimeInterval, timeout: TimeInterval) async -> Bool {
        let start = Date()
        while runtime.navigationGeneration == generation {
            if Date().timeIntervalSince(start) >= min(startGrace, timeout) { return false }
            await Self.sleep(0.05)
        }
        while runtime.automationState().navigationState == .loading, Date().timeIntervalSince(start) < timeout {
            await Self.sleep(0.05)
        }
        return true
    }

    private func state(_ target: Target) -> [String: AutomationJSONValue] {
        executor.linuxBrowserStateSnapshot(
            workspaceID: target.workspaceID,
            panelID: target.panelID,
            webState: target.webState,
            runtimeState: target.runtime.automationState()
        )
    }

    // MARK: Page commands

    /// One library call, retried while it reports a retryable failure (no
    /// match yet, hidden, disabled, covered) or the page is mid-navigation.
    private func page(_ target: Target, _ args: [String: Any], timeout: TimeInterval) async throws -> [String: AutomationJSONValue] {
        let host = try automationHost(target)
        let body = try LinuxBrowserAutomationScript.body(command: args)
        let start = Date()
        var lastError = "no result"
        while true {
            let generation = target.runtime.navigationGeneration
            do {
                let raw = try await host.callAutomationFunction(body, world: LinuxBrowserAutomationScript.worldName)
                guard let raw, let object = Self.jsonObject(raw) else {
                    throw AutomationSocketError.internalError("the page returned no result")
                }
                if case .bool(true)? = object["ok"] {
                    var result = object
                    result["ok"] = nil
                    result["retry"] = nil
                    return result
                }
                lastError = object.string("error") ?? "failed"
                if object.bool("retry") != true { throw AutomationSocketError.invalidPayload(lastError) }
            } catch let error as AutomationSocketError {
                throw error
            } catch {
                // The page navigated away under the call; retry on the new one.
                lastError = "\(error)"
                let navigating = target.runtime.automationState().navigationState == .loading
                    || target.runtime.navigationGeneration != generation
                if navigating == false { throw AutomationSocketError.invalidPayload(lastError) }
            }
            if Date().timeIntervalSince(start) >= timeout {
                let waited = timeout >= 1 ? " (waited \(Int(timeout.rounded()))s)" : ""
                throw AutomationSocketError.invalidPayload(lastError + waited)
            }
            await Self.sleep(0.1)
        }
    }

    private func act(_ verb: String, _ target: Target, _ payload: [String: AutomationJSONValue], timeout: TimeInterval) async throws -> [String: AutomationJSONValue] {
        var args = Self.plainArguments(payload)
        switch verb {
        case "dblclick":
            args["op"] = "click"
            args["count"] = 2
        case "check", "uncheck":
            args["op"] = "check"
            args["checked"] = verb == "check"
        case "upload":
            args["op"] = "upload"
            args["files"] = try Self.uploadFiles(payload.stringArray("files"))
        default:
            args["op"] = verb
        }
        if ["click", "dblclick", "hover", "focus", "fill", "select", "check", "uncheck", "upload"].contains(verb),
           payload.string("target") == nil {
            throw AutomationSocketError.invalidPayload("\(verb) needs a target (a snapshot ref like e12, a CSS selector, or text=…)")
        }
        let before = target.runtime.navigationGeneration
        var result = try await page(target, args, timeout: timeout)
        if ["click", "dblclick", "press", "check", "uncheck", "select", "fill", "type"].contains(verb) {
            // A click or Enter may start a navigation a moment later.
            let navigated = await waitForNavigation(
                target.runtime, after: before, startGrace: 0.3,
                timeout: Self.timeout(payload, default: Self.defaultNavigationTimeout)
            )
            result["navigated"] = .bool(navigated)
        }
        let runtimeState = target.runtime.automationState()
        result["panelID"] = .string(target.panelID.uuidString)
        result["url"] = runtimeState.observedURL.map { .string($0) } ?? .null
        result["title"] = runtimeState.title.map { .string($0) } ?? .null
        return result
    }

    private func evaluate(_ target: Target, _ payload: [String: AutomationJSONValue]) async throws -> [String: AutomationJSONValue] {
        guard let code = payload.string("code") else { throw AutomationSocketError.invalidPayload("code is required") }
        let host = try automationHost(target)
        var raw: String?
        do {
            raw = try await host.callAutomationFunction(LinuxBrowserAutomationScript.evaluationBody(code, asExpression: true), world: nil)
        } catch where "\(error)".contains("SyntaxError") {
            // Statements (`const x = …; return x`) rather than an expression.
            do {
                raw = try await host.callAutomationFunction(LinuxBrowserAutomationScript.evaluationBody(code, asExpression: false), world: nil)
            } catch {
                throw AutomationSocketError.invalidPayload("\(error)")
            }
        } catch {
            throw AutomationSocketError.invalidPayload("\(error)")
        }
        let value = raw.flatMap(Self.jsonObject)?["value"] ?? .null
        return ["panelID": .string(target.panelID.uuidString), "value": value]
    }

    private func wait(_ target: Target, _ payload: [String: AutomationJSONValue], timeout: TimeInterval) async throws -> [String: AutomationJSONValue] {
        guard let kind = payload.string("kind") else { throw AutomationSocketError.invalidPayload("kind is required") }
        let value = payload.string("value") ?? ""
        let start = Date()
        let host = try automationHost(target)
        var idleSince: Date?
        while true {
            let met: Bool
            switch kind {
            case "url":
                met = Self.urlMatches(target.runtime.automationState().observedURL, pattern: value)
            case "load":
                let runtimeState = target.runtime.automationState()
                if runtimeState.navigationState == .loading || runtimeState.isLoading {
                    met = false
                } else {
                    met = (try? await probe(target, ["op": "probe", "kind": "ready"])) == true
                }
            case "idle":
                let quiet = host.automationRequestsInFlight == 0 && target.runtime.automationState().navigationState != .loading
                if quiet { idleSince = idleSince ?? Date() } else { idleSince = nil }
                met = idleSince.map { Date().timeIntervalSince($0) >= 0.5 } ?? false
            case "js":
                let raw = try? await host.callAutomationFunction(LinuxBrowserAutomationScript.evaluationBody(value, asExpression: true), world: nil)
                switch raw.flatMap(Self.jsonObject)?["value"] {
                case .bool(let flag)?: met = flag
                case .null?, nil: met = false
                case .int(let number)?: met = number != 0
                case .double(let number)?: met = number != 0
                case .string(let text)?: met = text.isEmpty == false
                default: met = true
                }
            case "text", "text-gone", "visible", "hidden":
                do {
                    met = try await probe(target, ["op": "probe", "kind": kind, "value": value])
                } catch let error as AutomationSocketError {
                    throw error
                } catch {
                    met = false
                }
            default:
                throw AutomationSocketError.invalidPayload("unknown wait condition: \(kind)")
            }
            if met {
                let runtimeState = target.runtime.automationState()
                return [
                    "panelID": .string(target.panelID.uuidString),
                    "elapsedMs": .int(Int(Date().timeIntervalSince(start) * 1000)),
                    "url": runtimeState.observedURL.map { .string($0) } ?? .null,
                ]
            }
            if Date().timeIntervalSince(start) >= timeout {
                throw AutomationSocketError.invalidPayload("timed out after \(Int(timeout.rounded()))s waiting for \(kind)\(value.isEmpty ? "" : " \(value)")")
            }
            await Self.sleep(0.1)
        }
    }

    private func probe(_ target: Target, _ args: [String: Any]) async throws -> Bool {
        let result = try await page(target, args, timeout: 0)
        return result.bool("met") == true
    }

    private func screenshot(_ target: Target, _ payload: [String: AutomationJSONValue]) async throws -> [String: AutomationJSONValue] {
        let host = try automationHost(target)
        let png: Data
        do {
            png = try await host.captureAutomationScreenshotPNG(fullPage: payload.bool("fullPage") == true)
        } catch {
            let attached = target.runtime.automationState().lifecycleState.automationLabel != "detached"
            throw AutomationSocketError.invalidPayload(attached
                ? "screenshot failed: \(error)"
                : "screenshot failed: the browser panel is not on screen (select its workspace and tab)")
        }
        let path: String
        if let requested = payload.string("path") {
            path = requested
        } else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("toastty-browser", isDirectory: true)
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            path = directory.appendingPathComponent("\(target.panelID.uuidString.prefix(8))-\(stamp).png").path
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
        var result: [String: AutomationJSONValue] = ["panelID": .string(target.panelID.uuidString), "path": .string(path), "bytes": .int(png.count)]
        if let size = Self.pngSize(png) {
            result["width"] = .int(size.width)
            result["height"] = .int(size.height)
        }
        return result
    }

    private func console(_ target: Target, _ payload: [String: AutomationJSONValue]) -> [String: AutomationJSONValue] {
        guard let host = try? automationHost(target) else { return ["entries": .array([])] }
        let since = payload.int("since") ?? 0
        let errorsOnly = payload.bool("errorsOnly") == true
        let entries = host.automationConsole.filter {
            $0.sequence > since && (errorsOnly == false || $0.level == "error" || $0.level == "pageerror")
        }
        let last = host.automationConsole.last?.sequence ?? since
        if payload.bool("clear") == true { host.clearAutomationConsole() }
        return [
            "panelID": .string(target.panelID.uuidString),
            "lastSequence": .int(last),
            "entries": .array(entries.map { entry in
                .object([
                    "sequence": .int(entry.sequence),
                    "level": .string(entry.level),
                    "text": .string(entry.text),
                    "url": entry.url.map { .string($0) } ?? .null,
                    "time": .string(Self.timestamp(entry.date)),
                ])
            }),
        ]
    }

    private func network(_ target: Target, _ payload: [String: AutomationJSONValue]) -> [String: AutomationJSONValue] {
        guard let host = try? automationHost(target) else { return ["entries": .array([])] }
        let since = payload.int("since") ?? 0
        let failedOnly = payload.bool("failedOnly") == true
        let entries = host.automationNetwork.filter { entry in
            entry.sequence > since && (failedOnly == false || entry.error != nil || (entry.status ?? 0) >= 400)
        }
        let last = host.automationNetwork.last?.sequence ?? since
        if payload.bool("clear") == true { host.clearAutomationNetwork() }
        return [
            "panelID": .string(target.panelID.uuidString),
            "lastSequence": .int(last),
            "inFlight": .int(host.automationRequestsInFlight),
            "entries": .array(entries.map { entry in
                .object([
                    "sequence": .int(entry.sequence),
                    "method": .string(entry.method),
                    "url": .string(entry.url),
                    "status": entry.status.map { .int($0) } ?? .null,
                    "mimeType": entry.mimeType.map { .string($0) } ?? .null,
                    "error": entry.error.map { .string($0) } ?? .null,
                    "finished": .bool(entry.isFinished),
                    "durationMs": entry.finishedAt.map { .int(Int($0.timeIntervalSince(entry.startedAt) * 1000)) } ?? .null,
                ])
            }),
        ]
    }

    // MARK: Helpers

    static func timeout(_ payload: [String: AutomationJSONValue], default value: TimeInterval) -> TimeInterval {
        guard let milliseconds = payload.int("timeoutMs") else { return value }
        return max(0, TimeInterval(milliseconds) / 1000)
    }

    static func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Page-library arguments: the payload minus routing keys.
    static func plainArguments(_ payload: [String: AutomationJSONValue]) -> [String: Any] {
        var args: [String: Any] = [:]
        for (key, value) in payload where ["verb", "panelID", "workspaceID", "windowID", "callerPanelID", "timeoutMs", "files"].contains(key) == false {
            args[key] = plain(value)
        }
        return args
    }

    static func plain(_ value: AutomationJSONValue) -> Any {
        switch value {
        case .string(let string): return string
        case .int(let int): return int
        case .double(let double): return double
        case .bool(let bool): return bool
        case .null: return NSNull()
        case .array(let values): return values.map(plain)
        case .object(let object): return object.mapValues(plain)
        }
    }

    static func json(_ value: Any) -> AutomationJSONValue {
        switch value {
        case let string as String: return .string(string)
        case let number as NSNumber:
            // JSONSerialization booleans are NSNumbers of type "c".
            if String(cString: number.objCType) == "c" { return .bool(number.boolValue) }
            let double = number.doubleValue
            if double == double.rounded(), abs(double) < 1e15 { return .int(number.intValue) }
            return .double(double)
        case let array as [Any]: return .array(array.map(json))
        case let object as [String: Any]: return .object(object.mapValues(json))
        default: return .null
        }
    }

    static func jsonObject(_ text: String) -> [String: AutomationJSONValue]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) as? [String: Any] else {
            return nil
        }
        return object.mapValues(json)
    }

    static func uploadFiles(_ paths: [String]) throws -> [[String: Any]] {
        guard paths.isEmpty == false else { throw AutomationSocketError.invalidPayload("upload needs at least one file") }
        var total = 0
        return try paths.map { path in
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url) else {
                throw AutomationSocketError.invalidPayload("cannot read \(path)")
            }
            total += data.count
            guard total <= maximumUploadBytes else {
                throw AutomationSocketError.invalidPayload("upload is larger than \(maximumUploadBytes >> 20) MB")
            }
            return ["name": url.lastPathComponent, "type": mimeType(for: url.pathExtension), "base64": data.base64EncodedString()]
        }
    }

    static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "txt", "log": return "text/plain"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "html", "htm": return "text/html"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    /// Substring match, or a `*` glob over the whole URL.
    static func urlMatches(_ url: String?, pattern: String) -> Bool {
        guard let url else { return false }
        guard pattern.contains("*") else { return url.contains(pattern) }
        let regex = "^" + pattern.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: ".*") + "$"
        return url.range(of: regex, options: .regularExpression) != nil
    }

    static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24 else { return nil }
        let bytes = [UInt8](data.prefix(24))
        func be(_ offset: Int) -> Int { bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
        return (be(16), be(20))
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
