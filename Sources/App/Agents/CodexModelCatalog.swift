import Foundation
import RemoteProtocol

/// Uses the CLI's catalog and refresh policy without starting a session or
/// depending on Toastty's remote-access transcript readers.
struct CodexModelCatalog: Sendable {
    private let executor: any CodexPluginCLIExecuting

    init(executor: any CodexPluginCLIExecuting = CodexPluginCLIProcessExecutor()) {
        self.executor = executor
    }

    /// Blocking I/O: call off the main actor. Older CLIs can reject this
    /// command; callers must keep Default and manual model entry available.
    func load(runtime: CodexIntegrationRuntime, deadline: Date) throws -> [String] {
        let data = try executor.execute(runtime: runtime, arguments: ["debug", "models"], deadline: deadline)
        return try Self.models(in: data)
    }

    static func models(in data: Data) throws -> [String] {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        var seen: Set<String> = []
        return catalog.models.compactMap { entry in
            guard entry.visibility == "list", let slug = entry.slug,
                  RemoteSessionStartPolicy.isValidSelectionValue(slug, maximumLength: RemoteSessionStartPolicy.maximumModelLength),
                  seen.insert(slug).inserted else { return nil }
            return slug
        }
    }

    private struct Catalog: Decodable {
        let models: [Entry]
    }

    private struct Entry: Decodable {
        let slug: String?
        let visibility: String?

        private enum CodingKeys: String, CodingKey { case slug, visibility }

        init(from decoder: any Decoder) throws {
            // An unusable entry must not hide the rest of the catalog.
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            slug = try? container?.decode(String.self, forKey: .slug)
            visibility = try? container?.decode(String.self, forKey: .visibility)
        }
    }
}
