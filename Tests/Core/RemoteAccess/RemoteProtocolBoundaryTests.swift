import Foundation
import RemoteProtocol
import Testing

struct RemoteProtocolBoundaryTests {
    @Test func sharedModuleImportsFoundationOnly() throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RemoteProtocol", isDirectory: true)

        let sourceFiles = try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        #expect(sourceFiles.isEmpty == false)
        for sourceFile in sourceFiles {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            let importedModules = source.split(separator: "\n").compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("import ") {
                    return String(trimmed.dropFirst("import ".count))
                }
                if trimmed.hasPrefix("@_exported import ") {
                    return String(trimmed.dropFirst("@_exported import ".count))
                }
                return nil
            }
            #expect(
                importedModules == ["Foundation"],
                "\(sourceFile.lastPathComponent) must remain Foundation-only"
            )
        }
    }

    @Test func deviceSummaryScopesHaveStableWireOrder() {
        let summary = RemoteGatewayDeviceSummary(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            name: "Phone",
            scopes: [.send, .approve, .read]
        )

        #expect(summary.scopes == [.approve, .read, .send])
    }
}
