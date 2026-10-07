import Foundation

enum TailscaleServeSetupError: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case detection(TailscaleTailnetOriginDetectionError)
    case originMismatch
    case portInUse(UInt16)
    case noAvailableHTTPSPort
    case funnelEnabled
    case notConfigured
    case statusUnavailable
    case configurationFailed
    case approvalRequired(URL)
    case timedOut
    case identityChanged

    var description: String { "<redacted Tailscale setup failure>" }
    var debugDescription: String { description }

    var approvalURL: URL? {
        guard case .approvalRequired(let url) = self else { return nil }
        return url
    }

    var title: String {
        switch self {
        case .detection, .statusUnavailable: "Tailscale Serve is not verified"
        case .originMismatch: "Tailscale address does not match"
        case .portInUse(let port): "Tailscale HTTPS port \(port) is in use"
        case .noAvailableHTTPSPort: "No Tailscale HTTPS port is available"
        case .funnelEnabled: "Public Tailscale Funnel access is enabled"
        case .notConfigured: "Tailscale Serve is not configured"
        case .configurationFailed: "Tailscale Serve setup failed"
        case .approvalRequired: "Tailscale setup needs approval"
        case .timedOut: "Tailscale Serve setup timed out"
        case .identityChanged: "Tailscale account or address changed"
        }
    }

    var recoveryMessage: String {
        switch self {
        case .detection(let error):
            error.recoveryMessage
        case .originMismatch:
            "The saved address does not match this Mac’s Tailscale address. Choose Detect to update it, then try setup again."
        case .portInUse(let port):
            "Tailscale HTTPS port \(port) has a different setup. Toastty will not replace it or move existing pairings. Restore the Toastty mapping on that port, then choose Retry Setup."
        case .noAvailableHTTPSPort:
            "Tailscale HTTPS port 443 and fallback ports 8443–8447 are occupied. Free one of those ports in Tailscale Serve, then choose Retry Setup."
        case .funnelEnabled:
            "Tailscale Funnel exposes the selected HTTPS port or the Toastty gateway publicly. Turn off that Funnel access before pairing with Toastty."
        case .notConfigured:
            "Tailscale Serve is not configured for Toastty. Choose Retry Setup to configure access from your phone."
        case .statusUnavailable:
            "Toastty could not check the Tailscale Serve mapping. Check that Tailscale is running and up to date, then try again."
        case .configurationFailed:
            "Tailscale Serve did not create the HTTPS connection to Toastty. Check that Tailscale is up to date and that your account can change Serve settings, then try again."
        case .approvalRequired:
            "Tailscale needs approval to enable HTTPS. Open Tailscale Setup in your browser, complete the steps, then try again. Your tailnet administrator may need to approve it."
        case .timedOut:
            "Tailscale Serve did not finish setup in time, and Toastty’s HTTPS connection is not configured. Check Tailscale, then choose Retry Setup."
        case .identityChanged:
            "The Tailscale account or Mac address changed during setup. Check the active Tailscale account, then try again."
        }
    }
}

enum TailscaleServeConfigurationState: Equatable {
    case available
    case configured
}

/// Uses the same supported Serve command as manual setup, with a conflict
/// check immediately before the write and verification of the resulting state.
/// The CLI has no create-only operation; concurrent external edits between our
/// check and the CLI's own read are outside this transaction.
struct TailscaleServeSetup: Sendable {
    typealias CommandRunner = @Sendable (URL, [String], TimeInterval) async throws -> TailscaleCommandResult

    private let detector: TailscaleTailnetOriginDetector
    private let commandRunner: CommandRunner
    private let commandTimeout: TimeInterval

    init(
        detector: TailscaleTailnetOriginDetector = .init(),
        commandTimeout: TimeInterval = 8,
        commandRunner: @escaping CommandRunner = TailscaleStatusCommandRunner.runResult
    ) {
        self.detector = detector
        self.commandTimeout = commandTimeout
        self.commandRunner = commandRunner
    }

    func run(port: UInt16, configuredOrigin: String, configureIfNeeded: Bool) async throws -> String {
        let client: TailscaleClientIdentity
        do {
            client = try await detector.detectClient()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TailscaleTailnetOriginDetectionError {
            throw TailscaleServeSetupError.detection(error)
        }
        let savedOrigin = configuredOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedURL = RemoteAccessService.publicGatewayURL(from: savedOrigin)
        guard let clientHost = URL(string: client.origin)?.host,
              savedOrigin.isEmpty || savedURL?.host == clientHost else {
            throw TailscaleServeSetupError.originMismatch
        }
        let before = try await configuration(client: client)
        let origin = try before.selectOrigin(
            clientOrigin: client.origin, savedOrigin: savedURL?.absoluteString, gatewayPort: port
        )
        guard let selectedURL = URL(string: origin),
              let httpsPort = UInt16(exactly: selectedURL.port ?? 443), httpsPort > 0 else {
            throw TailscaleServeSetupError.statusUnavailable
        }
        if try before.state(origin: origin, port: port) == .configured {
            try await verifyIdentity(client)
            return origin
        }
        guard configureIfNeeded else {
            try await verifyIdentity(client)
            throw TailscaleServeSetupError.notConfigured
        }

        // Recheck the selected port immediately before writing. Never select a
        // different address after this point; a concurrent edit must be reported.
        let preflight = try await configuration(client: client)
        if try preflight.state(origin: origin, port: port) == .configured {
            try await verifyIdentity(client)
            return origin
        }
        try await verifyIdentity(client)
        try Task.checkCancellation()

        let result: TailscaleCommandResult?
        do {
            result = try await commandRunner(
                client.executableURL,
                ["serve", "--bg", "--https=\(httpsPort)", "http://127.0.0.1:\(port)"],
                commandTimeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A failed child can still have written the mapping. Inspect the
            // actual result before deciding whether another attempt is needed.
            result = nil
        }
        try Task.checkCancellation()
        let afterResult: Result<TailscaleServeConfigurationState, Error>
        do {
            afterResult = .success(try await configuration(client: client).state(origin: origin, port: port))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            afterResult = .failure(error)
        }
        // A profile switch can make the new mapping look like a conflict with
        // the old hostname. Report the identity change before that verdict.
        try await verifyIdentity(client)
        let after = try afterResult.get()
        if after == .configured { return origin }

        if let result {
            if let url = Self.approvalURL(in: result.stdout) ?? Self.approvalURL(in: result.stderr) {
                throw TailscaleServeSetupError.approvalRequired(url)
            }
            if result.timedOut { throw TailscaleServeSetupError.timedOut }
        }
        throw TailscaleServeSetupError.configurationFailed
    }

    private func configuration(client: TailscaleClientIdentity) async throws -> ServeConfiguration {
        do {
            let result = try await commandRunner(client.executableURL, ["serve", "status", "--json"], 3)
            try Task.checkCancellation()
            guard result.exitCode == 0, !result.timedOut else { throw TailscaleServeSetupError.statusUnavailable }
            return try Self.decodeConfiguration(result.stdout)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TailscaleServeSetupError {
            throw error
        } catch {
            throw TailscaleServeSetupError.statusUnavailable
        }
    }

    private func verifyIdentity(_ client: TailscaleClientIdentity) async throws {
        do {
            let result = try await commandRunner(client.executableURL, ["status", "--json", "--peers=false"], 3)
            try Task.checkCancellation()
            guard result.exitCode == 0, !result.timedOut,
                  try TailscaleTailnetOriginDetector.clientIdentity(
                    fromStatusJSON: result.stdout, executableURL: client.executableURL
                  ) == client else { throw TailscaleServeSetupError.identityChanged }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TailscaleServeSetupError.identityChanged
        }
    }

    static func approvalURL(in data: Data) -> URL? {
        guard data.count <= 256 * 1_024, let output = String(data: data, encoding: .utf8) else { return nil }
        // Tailscale prints the feature-approval URL on its own line. Do not
        // infer links from prose, arbitrary stderr, or a different control host.
        for line in output.split(whereSeparator: \.isNewline) {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard candidate.utf8.count <= 2_048,
                  let components = URLComponents(string: candidate),
                  components.scheme == "https", components.host == "login.tailscale.com",
                  components.user == nil, components.password == nil,
                  components.port == nil, components.fragment == nil,
                  components.path.hasPrefix("/f/"),
                  let url = components.url else { continue }
            return url
        }
        return nil
    }

    static func configurationState(from data: Data, origin: String, port: UInt16) throws -> TailscaleServeConfigurationState {
        try decodeConfiguration(data).state(origin: origin, port: port)
    }

    private static func decodeConfiguration(_ data: Data) throws -> ServeConfiguration {
        do {
            guard data.count <= 256 * 1_024 else { throw TailscaleServeSetupError.statusUnavailable }
            // The CLI emits null before the first Serve configuration.
            return try JSONDecoder().decode(ServeConfiguration?.self, from: data) ?? ServeConfiguration()
        } catch {
            throw TailscaleServeSetupError.statusUnavailable
        }
    }
}

private struct ServeConfiguration: Decodable {
    struct TCPHandler: Decodable {
        var HTTPS: Bool?
        var HTTP: Bool?
        var TCPForward: String?
        var TerminateTLS: String?
        var isHTTPS: Bool { HTTPS == true && HTTP != true && (TCPForward ?? "").isEmpty && (TerminateTLS ?? "").isEmpty }
    }
    struct WebServer: Decodable {
        struct Handler: Decodable {
            var Proxy: String?
            var Path: String?
            var Text: String?

            func forwards(to port: UInt16) -> Bool {
                guard (Path ?? "").isEmpty, (Text ?? "").isEmpty,
                      let Proxy, let url = URLComponents(string: Proxy),
                      url.scheme == "http", let host = url.host, ["127.0.0.1", "localhost"].contains(host),
                      url.port == Int(port), url.user == nil, url.password == nil,
                      url.query == nil, url.fragment == nil else { return false }
                return url.path.isEmpty || url.path == "/"
            }
        }
        var Handlers: [String: Handler]?
    }
    var TCP: [String: TCPHandler]?
    var Web: [String: WebServer]?
    var AllowFunnel: [String: Bool]?
    var Foreground: [String: ServeConfiguration]?

    private var configurations: [ServeConfiguration] {
        [self] + (Foreground ?? [:]).values.flatMap(\.configurations)
    }

    private func uses(port: UInt16) -> Bool {
        configurations.contains { configuration in
            configuration.TCP?[String(port)] != nil
                || (configuration.Web ?? [:]).keys.contains { Self.port(in: $0) == port }
                || (configuration.AllowFunnel ?? [:]).contains { Self.port(in: $0.key) == port && $0.value }
        }
    }

    private static func port(in hostPort: String) -> UInt16? {
        hostPort.split(separator: ":").last.flatMap { UInt16($0) }
    }

    private func hasFunnel(on port: UInt16) -> Bool {
        configurations.contains { configuration in
            (configuration.AllowFunnel ?? [:]).contains { Self.port(in: $0.key) == port && $0.value }
        }
    }

    private func hasFunnelExposingGateway(port: UInt16, nodeOrigin: String, selectedOrigin: String? = nil) -> Bool {
        let all = configurations
        let hostname = URL(string: nodeOrigin)?.host ?? ""
        let publicPorts = Set(all.flatMap { configuration in
            (configuration.AllowFunnel ?? [:]).compactMap { $0.value ? Self.port(in: $0.key) : nil }
        })
        var targets: [String: [String]] = [:]
        for configuration in all {
            for (hostPort, web) in configuration.Web ?? [:] {
                targets[hostPort.lowercased(), default: []] += (web.Handlers ?? [:]).values.compactMap(\.Proxy)
            }
            for (httpsPort, tcp) in configuration.TCP ?? [:] {
                if let target = tcp.TCPForward {
                    targets["\(hostname):\(httpsPort)".lowercased(), default: []].append(target)
                }
            }
        }
        var gatewayOrigins: Set<String> = []
        if let selectedOrigin, let url = URL(string: selectedOrigin), let host = url.host {
            gatewayOrigins.insert("\(host):\(url.port ?? 443)".lowercased())
        }
        // Follow only the destinations explicitly recorded in Serve status.
        // This finite set also catches public proxies through another local
        // Serve route. No DNS lookup or network probe can change this decision.
        var foundOrigin = true
        while foundOrigin {
            foundOrigin = false
            for (origin, destinations) in targets where !gatewayOrigins.contains(origin) {
                if destinations.contains(where: { Self.targetsGateway($0, port: port, origins: gatewayOrigins) }) {
                    gatewayOrigins.insert(origin)
                    foundOrigin = true
                }
            }
        }
        return gatewayOrigins.contains { origin in
            Self.port(in: origin).map { publicPorts.contains($0) } ?? false
        }
    }

    /// Reuse requires an exact root HTTP proxy. Exposure checks are stricter:
    /// an unknown destination or a proxy to the backend port cannot prove that
    /// access stays private, even when it uses another loopback spelling.
    private static func targetsGateway(_ target: String, port: UInt16, origins: Set<String>) -> Bool {
        if UInt16(target) == port { return true }
        let candidate = target.contains("://") ? target : "http://" + target
        guard let url = URLComponents(string: candidate) else { return true }
        let targetPort = url.port ?? (url.scheme == "http" ? 80 : 443)
        guard (1...65535).contains(targetPort) else { return true }
        if targetPort == Int(port) { return true }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return true }
        return origins.contains("\(host):\(targetPort)")
    }

    func selectOrigin(clientOrigin: String, savedOrigin: String?, gatewayPort: UInt16) throws -> String {
        guard !hasFunnelExposingGateway(port: gatewayPort, nodeOrigin: clientOrigin) else { throw TailscaleServeSetupError.funnelEnabled }
        if let savedOrigin {
            _ = try state(origin: savedOrigin, port: gatewayPort)
            return savedOrigin
        }
        let candidates: [UInt16] = [443, 8443, 8444, 8445, 8446, 8447]
        var firstAvailable: String?
        for candidate in candidates where candidate != gatewayPort {
            let origin = candidate == 443 ? clientOrigin : "\(clientOrigin):\(candidate)"
            do {
                // Recover a mapping written before cancellation or a crash,
                // before creating another one. Prefer an existing 443 mapping.
                if try state(origin: origin, port: gatewayPort) == .configured { return origin }
                if firstAvailable == nil { firstAvailable = origin }
            } catch TailscaleServeSetupError.portInUse {
                continue
            } catch TailscaleServeSetupError.funnelEnabled {
                continue
            }
        }
        guard let firstAvailable else { throw TailscaleServeSetupError.noAvailableHTTPSPort }
        return firstAvailable
    }

    func state(origin: String, port: UInt16) throws -> TailscaleServeConfigurationState {
        guard let url = URL(string: origin), let hostname = url.host,
              let httpsPort = UInt16(exactly: url.port ?? 443), httpsPort > 0 else {
            throw TailscaleServeSetupError.originMismatch
        }
        guard !hasFunnel(on: httpsPort), !hasFunnelExposingGateway(port: port, nodeOrigin: origin, selectedOrigin: origin) else {
            throw TailscaleServeSetupError.funnelEnabled
        }
        guard !(Foreground ?? [:]).values.contains(where: { $0.uses(port: httpsPort) }) else {
            throw TailscaleServeSetupError.portInUse(httpsPort)
        }
        guard uses(port: httpsPort) else { return .available }
        guard TCP?[String(httpsPort)]?.isHTTPS == true,
              Web?["\(hostname):\(httpsPort)"]?.Handlers?["/"]?.forwards(to: port) == true else {
            throw TailscaleServeSetupError.portInUse(httpsPort)
        }
        return .configured
    }
}
