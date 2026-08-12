import Foundation

public enum ToasttyMobileRuntimeMode: Equatable, Sendable {
    case unconfigured
    case fixture
    case local(gatewayURL: URL)
    case live(gatewayURL: URL)

    public init(environment: [String: String], bundledGatewayURL: URL? = nil) {
#if DEBUG
        if environment["TOASTTY_MOBILE_USE_FIXTURE"] == "1" {
            self = .fixture
            return
        }
#endif

        let gatewayURL: URL
        if let environmentValue = environment["TOASTTY_MOBILE_GATEWAY_URL"] {
            let normalizedEnvironmentValue = environmentValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedEnvironmentValue.isEmpty {
                guard let bundledGatewayURL, Self.isSupportedGatewayURL(bundledGatewayURL) else {
                    self = .unconfigured
                    return
                }
                gatewayURL = bundledGatewayURL
            } else if let environmentURL = Self.gatewayURL(from: normalizedEnvironmentValue) {
                gatewayURL = environmentURL
            } else {
                self = .unconfigured
                return
            }
        } else if let bundledGatewayURL, Self.isSupportedGatewayURL(bundledGatewayURL) {
            gatewayURL = bundledGatewayURL
        } else {
            self = .unconfigured
            return
        }

        if gatewayURL.scheme?.lowercased() == "http", gatewayURL.isLoopbackHost {
            self = .local(gatewayURL: gatewayURL)
        } else {
            self = .live(gatewayURL: gatewayURL)
        }
    }

    public var displayName: String {
        switch self {
        case .unconfigured: "unconfigured"
        case .fixture: "fixture"
        case .local: "local"
        case .live: "live"
        }
    }

    private static func gatewayURL(from value: String) -> URL? {
        guard let url = URL(string: value),
              isSupportedGatewayURL(url)
        else {
            return nil
        }
        return url
    }

    private static func isSupportedGatewayURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else {
            return false
        }
        return true
    }
}

private extension URL {
    var isLoopbackHost: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1"
            || host == "::1"
            || host == "localhost"
            || host.hasSuffix(".localhost")
    }
}
