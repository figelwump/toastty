import Foundation

public enum ToasttyMobileRuntimeMode: Equatable, Sendable {
    case fixture
    case local(gatewayURL: URL)
    case live(gatewayURL: URL)

    public init(environment: [String: String], bundledGatewayURL: URL? = nil) {
        if environment["TOASTTY_MOBILE_USE_FIXTURE"] == "1" {
            self = .fixture
            return
        }

        let environmentURL = environment["TOASTTY_MOBILE_GATEWAY_URL"].flatMap(URL.init(string:))
        guard let gatewayURL = environmentURL ?? bundledGatewayURL else {
            self = .fixture
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
        case .fixture: "fixture"
        case .local: "local"
        case .live: "live"
        }
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
