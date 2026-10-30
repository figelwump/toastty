import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct RemoteLocalServerPreviewsTests {
    @Test func recognizesOnlyPlainHTTPLoopbackServers() {
        let cases: [(String, UInt16?)] = [
            ("http://127.0.0.1:8082/?reload=1", 8082),
            ("http://localhost:5173", 5173),
            ("http://app.localhost:3000/", 3000),
            ("http://0.0.0.0:8000", 8000),
            ("http://localhost/", 80),
            ("https://localhost:8443", nil),
            ("http://[::1]:3000", nil),
            ("http://user:pw@localhost:3000", nil),
            ("http://example.com:8082", nil),
            ("http://127.example.com:8082", nil),
        ]
        for (raw, port) in cases {
            #expect(RemoteLocalServerPreviews.loopbackPort(of: URL(string: raw)!) == port, "\(raw)")
        }
    }

    @Test func rewritesOntoTheTailnetKeepingPathQueryAndFragment() async throws {
        let previews = RemoteLocalServerPreviews(fileURL: nil, expose: { _ in ("https://mac.tailnet.ts.net:8082", true) }, remove: { _ in })
        let url = try await previews.phoneURL(for: URL(string: "http://127.0.0.1:8082/view?reload=2#cam")!)
        #expect(url.absoluteString == "https://mac.tailnet.ts.net:8082/view?reload=2#cam")
        let remote = URL(string: "https://example.com/")!
        #expect(try await previews.phoneURL(for: remote) == remote)
    }

    @Test func removesOnlyMappingsItCreatedAndRemembersThemAcrossRuns() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-local-previews-\(UUID().uuidString)/ports.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let removed = Recorder()
        let first = RemoteLocalServerPreviews(
            fileURL: file,
            expose: { port in ("https://mac.tailnet.ts.net:\(port)", port != 3000) },
            remove: { await removed.append($0) }
        )
        for port in [8082, 5173, 3000] {
            _ = try await first.phoneURL(for: URL(string: "http://localhost:\(port)/")!)
        }
        first.removeMappings(except: [5173])
        // A later run (after a quit or crash) still knows about 5173.
        let second = RemoteLocalServerPreviews(fileURL: file, expose: { _ in ("", false) }, remove: { await removed.append($0) })
        second.removeMappings()
        for _ in 0..<100 where await removed.ports.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await removed.ports.sorted() == [5173, 8082])
    }

    private actor Recorder {
        var ports: [UInt16] = []
        func append(_ port: UInt16) { ports.append(port) }
    }
}
