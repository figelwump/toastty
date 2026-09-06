import CoreState
import Darwin
import Foundation

struct RemotePanelMetadataSource: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case localFile
        case scratchpad(revision: Int)
    }
    var path: String
    var kind: Kind
}

enum RemotePanelMetadataObservation: Equatable, Sendable {
    case present(modifiedAt: Date)
    case missing
    case unknown
}

/// Metadata only: no file content is opened or read. Walk through directory
/// descriptors without following custom symlinks so a dangling link cannot be
/// mistaken for a deleted source. Only normal macOS aliases are expanded.
enum RemotePanelMetadataProbe {
    static func inspect(_ source: RemotePanelMetadataSource) -> RemotePanelMetadataObservation {
        guard !Task.isCancelled, source.path.hasPrefix("/"), source.path.utf8.count <= 4096,
            !source.path.utf8.contains(0)
        else { return .unknown }
        var components = source.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return .unknown }
        if let first = components.first, ["tmp", "var", "etc"].contains(first) {
            guard (try? RemotePreviewFileReader.authorityPath("/" + first)) == "/private/" + first
            else {
                return .unknown
            }
            components.insert("private", at: 0)
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return .unknown }
        defer { Darwin.close(descriptor) }
        for (index, component) in components.enumerated() {
            guard !Task.isCancelled else { return .unknown }
            var info = stat()
            let (result, error) = component.withCString { pointer in
                let result = fstatat(descriptor, pointer, &info, AT_SYMLINK_NOFOLLOW)
                return (result, errno)
            }
            guard result == 0 else {
                return error == ENOENT || error == ENOTDIR ? .missing : .unknown
            }
            let type = info.st_mode & S_IFMT
            guard type != S_IFLNK else { return .unknown }
            if index == components.count - 1 {
                guard type == S_IFREG else { return .unknown }
                return .present(
                    modifiedAt: Date(
                        timeIntervalSince1970:
                            Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec)
                            / 1_000_000_000))
            }
            guard type == S_IFDIR else { return .missing }
            let next = component.withCString {
                Darwin.openat(
                    descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            }
            // A rename or symlink replacement between stat and open is an
            // inconclusive observation, rather than permission to hide a row.
            guard next >= 0 else { return .unknown }
            Darwin.close(descriptor)
            descriptor = next
        }
        return .unknown
    }
}

@MainActor
final class RemotePanelMetadataCache {
    struct Input: Equatable, Sendable {
        var source: RemotePanelMetadataSource?
        var recentActivityAt: Date?
    }
    struct Metadata: Equatable, Sendable {
        var updatedAt: Date?
        var isConfirmedMissing: Bool
    }
    typealias Probe =
        @Sendable ([RemotePanelMetadataSource]) async -> [RemotePanelMetadataSource:
        RemotePanelMetadataObservation]

    private let probe: Probe
    private var inputs: [UUID: Input] = [:]
    private var observations: [RemotePanelMetadataSource: RemotePanelMetadataObservation] = [:]
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isActive = false
    private var refreshAgain = false
    private var lastRefresh: ContinuousClock.Instant?
    private(set) var metadata: [UUID: Metadata] = [:]
    var onChange: (() -> Void)?
    var isRefreshing: Bool { task != nil }

    init(
        probe: @escaping Probe = { sources in
            var result: [RemotePanelMetadataSource: RemotePanelMetadataObservation] = [:]
            for source in sources {
                guard !Task.isCancelled else { break }
                result[source] = RemotePanelMetadataProbe.inspect(source)
            }
            return result
        }
    ) {
        self.probe = probe
    }

    deinit { task?.cancel() }

    func start() { isActive = true }

    func stop() {
        isActive = false
        generation &+= 1
        task?.cancel()
        refreshAgain = false
        lastRefresh = nil
        inputs = [:]
        observations = [:]
        metadata = [:]
    }

    func updateInputs(_ next: [UUID: Input]) {
        guard isActive, inputs != next else { return }
        let previousSources = Set(inputs.values.compactMap(\.source))
        inputs = next
        let sources = Set(next.values.compactMap(\.source))
        observations = observations.filter { sources.contains($0.key) }
        publishIfChanged()
        requestRefresh(force: sources != previousSources)
    }

    func requestRefresh(force: Bool = false) {
        guard isActive else { return }
        let sources = Array(Set(inputs.values.compactMap(\.source)))
        guard !sources.isEmpty else { return }
        if task != nil {
            refreshAgain = refreshAgain || force
            return
        }
        if !force, let lastRefresh, lastRefresh.duration(to: .now) < .seconds(5) { return }
        let requestedGeneration = generation
        let probe = probe
        refreshAgain = false
        task = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .utility) { await probe(sources) }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self else { return }
            self.task = nil
            if self.isActive, self.generation == requestedGeneration, !Task.isCancelled {
                let currentSources = Set(self.inputs.values.compactMap(\.source))
                for source in sources where currentSources.contains(source) {
                    // Unknown replaces a previous missing observation.
                    self.observations[source] = result[source] ?? .unknown
                }
                self.lastRefresh = .now
                self.publishIfChanged()
            }
            if self.isActive, self.refreshAgain { self.requestRefresh(force: true) }
        }
    }

    private func publishIfChanged() {
        let next = inputs.mapValues { input in
            var modifiedAt: Date?
            var missing = false
            if let source = input.source {
                switch observations[source] ?? .unknown {
                case .present(let date): modifiedAt = date
                case .missing: missing = source.kind == .localFile
                case .unknown: break
                }
            }
            return Metadata(
                updatedAt: [input.recentActivityAt, modifiedAt].compactMap { $0 }.max(),
                isConfirmedMissing: missing)
        }
        guard metadata != next else { return }
        metadata = next
        onChange?()
    }
}
