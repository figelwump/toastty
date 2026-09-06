import Foundation
import RemoteProtocol

/// Deferred reads keep authentication on the gateway's existing execution context.
public struct RemoteGatewayPreviewOperation: Equatable, Sendable {
    public enum Request: Equatable, Sendable {
        case preview(RemotePreviewRequest)
        case resource(RemoteHTMLResourceRequest)
        public var target: RemotePreviewTarget {
            switch self {
            case .preview(let request): request.target
            case .resource(let request): request.target
            }
        }
    }
    public let deviceID: UUID
    public let request: Request
    public init(deviceID: UUID, request: Request) {
        self.deviceID = deviceID
        self.request = request
    }

    public func errorResponse(_ error: RemotePreviewError) -> RemoteGatewayHTTPResponse {
        let encoder = JSONEncoder()
        let body: Data
        switch request {
        case .preview: body = (try? encoder.encode(RemotePreviewResponse(error: error))) ?? Data()
        case .resource:
            body = (try? encoder.encode(RemoteHTMLResourceResponse(error: error))) ?? Data()
        }
        return .json(status: 200, reason: "OK", body: body)
    }
}
