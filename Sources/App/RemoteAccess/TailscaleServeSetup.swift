import Foundation

enum TailscaleServeSetupError: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case detection(TailscaleTailnetOriginDetectionError)
    case originMismatch
    case portInUse
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

    var recoveryMessage: String {
        switch self {
        case .detection(let error):
            error.recoveryMessage
        case .originMismatch:
            "The saved address does not match this Mac’s Tailscale address. Choose Detect to update it, then try setup again."
        case .portInUse:
            "Tailscale HTTPS port 443 already has a different setup. Toastty will not replace it. Check the existing Serve mapping before trying again."
        case .funnelEnabled:
            "Tailscale Funnel exposes HTTPS port 443 or the Toastty gateway publicly. Turn off that Funnel access before pairing with Toastty."
        case .notConfigured:
            "Tailscale Serve is not configured for Toastty. Choose Set Up Tailscale to connect this Mac."
        case .statusUnavailable:
            "Toastty could not check the Tailscale Serve mapping. Check that Tailscale is running and up to date, then try again."
        case .configurationFailed:
            "Tailscale could not configure HTTPS access. Check that Tailscale is up to date and that your account can change Serve settings, then try again."
        case .approvalRequired:
            "Tailscale needs approval to enable HTTPS. Open Tailscale Setup in your browser, complete the steps, then try again. Your tailnet administrator may need to approve it."
        case .timedOut:
            "Tailscale did not finish setup in time. Check Tailscale, then try again."
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
        guard savedOrigin.isEmpty || RemoteAccessService.publicGatewayURL(from: savedOrigin)?.absoluteString == client.origin else {
            throw TailscaleServeSetupError.originMismatch
        }

        // Keep this decision next to the CLI write. There is no UI or approval
        // wait between the last read and starting the command.
        let before = try await configuration(client: client, port: port)
        if before == .configured {
            try await verifyIdentity(client)
            return client.origin
        }
        guard configureIfNeeded else { throw TailscaleServeSetupError.notConfigured }
        try Task.checkCancellation()

        let result: TailscaleCommandResult?
        do {
            result = try await commandRunner(
                client.executableURL,
                ["serve", "--bg", "--https=443", "http://127.0.0.1:\(port)"],
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
            afterResult = .success(try await configuration(client: client, port: port))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            afterResult = .failure(error)
        }
        // A profile switch can make the new mapping look like a conflict with
        // the old hostname. Report the identity change before that verdict.
        try await verifyIdentity(client)
        let after = try afterResult.get()
        if after == .configured { return client.origin }

        if let result {
            if let url = Self.approvalURL(in: result.stdout) ?? Self.approvalURL(in: result.stderr) {
                throw TailscaleServeSetupError.approvalRequired(url)
            }
            if result.timedOut { throw TailscaleServeSetupError.timedOut }
        }
        throw TailscaleServeSetupError.configurationFailed
    }

    private func configuration(client: TailscaleClientIdentity, port: UInt16) async throws -> TailscaleServeConfigurationState {
        do {
            let result = try await commandRunner(client.executableURL, ["serve", "status", "--json"], 3)
            try Task.checkCancellation()
            guard result.exitCode == 0, !result.timedOut else { throw TailscaleServeSetupError.statusUnavailable }
            return try Self.configurationState(from: result.stdout, origin: client.origin, port: port)
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
        let configuration: ServeConfiguration
        do {
            guard data.count <= 256 * 1_024 else { throw TailscaleServeSetupError.statusUnavailable }
            // The CLI emits null before the first Serve configuration.
            configuration = try JSONDecoder().decode(ServeConfiguration?.self, from: data) ?? ServeConfiguration()
        } catch {
            throw TailscaleServeSetupError.statusUnavailable
        }
        return try configuration.state(origin: origin, port: port)
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

    private var hasFunnelOnHTTPSPort: Bool {
        (AllowFunnel ?? [:]).contains { $0.key.hasSuffix(":443") && $0.value }
            || (Foreground ?? [:]).values.contains { $0.hasFunnelOnHTTPSPort }
    }

    private var usesHTTPSPort: Bool {
        TCP?["443"] != nil || (Web ?? [:]).keys.contains { $0.hasSuffix(":443") }
            || (Foreground ?? [:]).values.contains { $0.usesHTTPSPort }
    }

    private func hasFunnelExposingGateway(port: UInt16) -> Bool {
        (AllowFunnel ?? [:]).contains { hostPort, enabled in
            enabled && (Web?[hostPort]?.Handlers ?? [:]).values.contains { $0.forwards(to: port) }
        } || (Foreground ?? [:]).values.contains { $0.hasFunnelExposingGateway(port: port) }
    }

    func state(origin: String, port: UInt16) throws -> TailscaleServeConfigurationState {
        guard !hasFunnelOnHTTPSPort, !hasFunnelExposingGateway(port: port) else {
            throw TailscaleServeSetupError.funnelEnabled
        }
        guard !(Foreground ?? [:]).values.contains(where: { $0.usesHTTPSPort }) else {
            throw TailscaleServeSetupError.portInUse
        }
        guard usesHTTPSPort else { return .available }
        guard let hostname = URL(string: origin)?.host,
              TCP?["443"]?.isHTTPS == true,
              Web?["\(hostname):443"]?.Handlers?["/"]?.forwards(to: port) == true else {
            throw TailscaleServeSetupError.portInUse
        }
        return .configured
    }
}
