import Foundation
import RemoteProtocol

/// Closed route catalog for the gateway. Unknown paths never inherit policy
/// from a neighboring endpoint, and known paths accept exactly one method.
enum RemoteGatewayRoute: CaseIterable, Hashable, Sendable {
    case preview
    case previewResource
    case hello
    case browserPair
    case nativePairingExchange
    case sessions
    case conversationEvents
    case conversationReadAcknowledge
    case questionAnswer
    case messageSend
    case subscribe
    case nativeDevice
    case nativeDeviceRevoke

    var path: String {
        switch self {
        case .preview: "/api/preview.get"
        case .previewResource: "/api/preview.resource.get"
        case .hello: "/api/hello"
        case .browserPair: "/api/pair"
        case .nativePairingExchange: "/v1/native-pairing/exchange"
        case .sessions: "/api/sessions"
        case .conversationEvents: "/api/conversation.events.get"
        case .conversationReadAcknowledge: "/api/conversation.read.acknowledge"
        case .questionAnswer: "/api/conversation.question.answer"
        case .messageSend: "/api/conversation.message.send"
        case .subscribe: "/api/subscribe"
        case .nativeDevice: "/v1/native-device"
        case .nativeDeviceRevoke: "/v1/native-device/revoke"
        }
    }
}

struct RemoteGatewayRoutePolicy: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// A presented Origin must be allowlisted, but it may be absent.
        case optionalAllowed
        /// Browser-cookie traffic must present an allowlisted Origin. Native
        /// Bearer traffic may omit it, but a presented value is still checked.
        case browserCredentialRequired
        /// An allowlisted Origin must be present.
        case requiredAllowed
        /// Any Origin or browser fetch metadata makes this route ineligible.
        case browserContextForbidden
    }

    enum Authentication: Equatable, Sendable {
        case none
        case browserPairing
        case browserOrNative
        case nativeBearer
    }

    enum Scope: Equatable, Sendable {
        case none
        case read
        case send
    }

    var route: RemoteGatewayRoute
    var method: String
    var origin: Origin
    var authentication: Authentication
    var scope: Scope

    static let fixed: [RemoteGatewayRoute: RemoteGatewayRoutePolicy] = [
        .preview: .init(route: .preview, method: "POST", origin: .optionalAllowed, authentication: .nativeBearer, scope: .read),
        .previewResource: .init(route: .previewResource, method: "POST", origin: .optionalAllowed, authentication: .nativeBearer, scope: .read),
        .hello: .init(route: .hello, method: "GET", origin: .optionalAllowed, authentication: .none, scope: .none),
        .browserPair: .init(route: .browserPair, method: "POST", origin: .requiredAllowed, authentication: .browserPairing, scope: .none),
        .nativePairingExchange: .init(route: .nativePairingExchange, method: "POST", origin: .browserContextForbidden, authentication: .none, scope: .none),
        .sessions: .init(route: .sessions, method: "GET", origin: .optionalAllowed, authentication: .browserOrNative, scope: .read),
        .conversationEvents: .init(route: .conversationEvents, method: "POST", origin: .browserCredentialRequired, authentication: .browserOrNative, scope: .read),
        .conversationReadAcknowledge: .init(route: .conversationReadAcknowledge, method: "POST", origin: .browserCredentialRequired, authentication: .browserOrNative, scope: .read),
        .questionAnswer: .init(route: .questionAnswer, method: "POST", origin: .optionalAllowed, authentication: .nativeBearer, scope: .send),
        .messageSend: .init(route: .messageSend, method: "POST", origin: .browserCredentialRequired, authentication: .browserOrNative, scope: .send),
        .subscribe: .init(route: .subscribe, method: "GET", origin: .browserCredentialRequired, authentication: .browserOrNative, scope: .read),
        .nativeDevice: .init(route: .nativeDevice, method: "GET", origin: .optionalAllowed, authentication: .nativeBearer, scope: .none),
        .nativeDeviceRevoke: .init(route: .nativeDeviceRevoke, method: "POST", origin: .optionalAllowed, authentication: .nativeBearer, scope: .none),
    ]

    static func policy(for path: String) -> RemoteGatewayRoutePolicy? {
        guard let route = RemoteGatewayRoute.allCases.first(where: { $0.path == path }) else {
            return nil
        }
        return fixed[route]
    }
}
