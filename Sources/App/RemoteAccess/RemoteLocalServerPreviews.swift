import CoreState
import Foundation
import RemoteProtocol

/// Lets a paired phone preview a browser panel showing a server that listens
/// only on this computer, such as `http://127.0.0.1:8082`. The phone loads a
/// browser preview's URL itself, so the loopback port is mapped onto the
/// tailnet with Tailscale Serve (HTTPS on the same port number) and the phone
/// gets `https://<this machine>.ts.net:8082/…` instead. Serve passes that host
/// name on, so a dev server that checks hosts must allow `.ts.net` names.
///
/// Mappings this class created are recorded in `fileURL` and removed once no
/// right-panel browser shows that port, when the last phone disconnects, and
/// when remote access turns off. The record outlives a quit or crash, so a
/// later run still removes them. A mapping that already existed is reused and
/// never removed.
@MainActor
final class RemoteLocalServerPreviews {
    typealias Expose = @Sendable (_ port: UInt16) async throws -> (origin: String, created: Bool)
    typealias Remove = @Sendable (_ port: UInt16) async throws -> Void

    private let fileURL: URL?
    private let expose: Expose
    private let remove: Remove
    private var createdPorts: Set<UInt16>
    private var removalTask: Task<Void, Never>?

    init(
        fileURL: URL?,
        expose: @escaping Expose = { try await TailscaleServeSetup().exposeLocalServer(port: $0) },
        remove: @escaping Remove = { try await TailscaleServeSetup().removeLocalServer(port: $0) }
    ) {
        self.fileURL = fileURL
        self.expose = expose
        self.remove = remove
        createdPorts = fileURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Set<UInt16>.self, from: $0) } ?? []
    }

    /// The port of an `http` URL whose host is this computer, which only the
    /// computer itself can load. HTTPS loopback servers (usually self-signed)
    /// and IPv6-only `[::1]` are left alone.
    nonisolated static func loopbackPort(of url: URL) -> UInt16? {
        guard url.scheme?.lowercased() == "http", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              host == "localhost" || host.hasSuffix(".localhost") || host == "0.0.0.0" || isIPv4Loopback(host)
        else { return nil }
        return UInt16(exactly: url.port ?? 80)
    }

    private nonisolated static func isIPv4Loopback(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil }
    }

    /// `url` rewritten onto the tailnet when it points at a loopback server
    /// (mapping the port first), or `url` unchanged otherwise.
    func phoneURL(for url: URL) async throws -> URL {
        guard let port = Self.loopbackPort(of: url) else { return url }
        await removalTask?.value
        let (origin, created) = try await expose(port)
        if created { record { $0.insert(port) } }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = URL(string: origin)?.host else { throw RemotePreviewError.unsupported }
        components.scheme = "https"
        components.host = host
        components.port = Int(port)
        guard let rewritten = components.url else { throw RemotePreviewError.unsupported }
        return rewritten
    }

    /// Removes the mappings this class created for ports not in `ports`.
    func removeMappings(except ports: Set<UInt16> = []) {
        let stale = createdPorts.subtracting(ports)
        guard stale.isEmpty == false else { return }
        record { $0.subtract(stale) }
        let previous = removalTask
        removalTask = Task { [remove] in
            await previous?.value
            for port in stale.sorted() {
                do {
                    try await remove(port)
                } catch {
                    ToasttyLog.warning(
                        "Could not remove the Tailscale Serve mapping for a local-server preview",
                        category: .automation,
                        metadata: ["port": String(port)]
                    )
                }
            }
        }
    }

    /// Loopback ports shown by right-panel browsers, the panels a phone can
    /// preview.
    nonisolated static func previewablePorts(in state: AppState) -> Set<UInt16> {
        var ports: Set<UInt16> = []
        for workspace in state.workspacesByID.values {
            for tab in workspace.orderedTabs {
                for panel in tab.rightAuxPanel.orderedTabs {
                    guard case .web(let web) = panel.panelState, web.definition == .browser,
                          let raw = web.currentURL ?? web.initialURL, let url = URL(string: raw),
                          let port = loopbackPort(of: url) else { continue }
                    ports.insert(port)
                }
            }
        }
        return ports
    }

    private func record(_ change: (inout Set<UInt16>) -> Void) {
        change(&createdPorts)
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(createdPorts).write(to: fileURL, options: .atomic)
        } catch {
            ToasttyLog.warning(
                "Could not record local-server preview mappings",
                category: .automation,
                metadata: ["underlying_error": String(reflecting: type(of: error))]
            )
        }
    }
}
