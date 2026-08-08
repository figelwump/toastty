import Combine
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct AnnotationStyleStoreTests {
    private static func makeRuntimePaths() -> (paths: ToasttyRuntimePaths, homeURL: URL) {
        let runtimeHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-style-store-tests-\(UUID().uuidString)", isDirectory: true)
        let paths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: runtimeHomeURL.path,
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHomeURL.path]
        )
        return (paths, runtimeHomeURL)
    }

    // MARK: - Token parsing

    @Test
    func tokenParsingAcceptsNamedColorsAndHexAndRejectsInvalidValues() {
        #expect(AnnotationColorToken.parse("green") == .named(.green))
        #expect(AnnotationColorToken.parse(" NEUTRAL ") == .named(.neutral))
        #expect(AnnotationColorToken.parse("#a1b2c3") == .hex("#A1B2C3"))
        #expect(AnnotationColorToken.parse("#A1B2C3") == .hex("#A1B2C3"))

        #expect(AnnotationColorToken.parse("") == nil)
        #expect(AnnotationColorToken.parse("chartreuse") == nil)
        #expect(AnnotationColorToken.parse("#12345") == nil)
        #expect(AnnotationColorToken.parse("#1234567") == nil)
        #expect(AnnotationColorToken.parse("#GGGGGG") == nil)
        #expect(AnnotationColorToken.parse("A1B2C3") == nil)
    }

    // MARK: - Fallback determinism

    @Test
    func fallbackTokenIsDeterministicPerKey() {
        let first = AnnotationStyleStore.fallbackColorToken(forKey: "pr")
        #expect(first == AnnotationStyleStore.fallbackColorToken(forKey: "pr"))

        // Different keys can share palette entries, but the mapping itself
        // must be a pure function of the key bytes.
        let keys = ["pr", "env", "build", "review", "deploy", "issue"]
        let firstRun = keys.map { AnnotationStyleStore.fallbackColorToken(forKey: $0) }
        let secondRun = keys.map { AnnotationStyleStore.fallbackColorToken(forKey: $0) }
        #expect(firstRun == secondRun)
    }

    // MARK: - Persistence

    @Test
    func setColorPersistsAtomicallyAndReloadsInNewStore() throws {
        let (paths, homeURL) = Self.makeRuntimePaths()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let store = AnnotationStyleStore(runtimePaths: paths)

        #expect(try store.setColor(.named(.green), forKey: "pr"))
        #expect(try store.setColor(.hex("#A1B2C3"), forKey: "env"))

        let reloaded = AnnotationStyleStore(runtimePaths: paths)
        #expect(reloaded.effectiveColorToken(forKey: "pr") == .named(.green))
        #expect(reloaded.effectiveColorToken(forKey: "env") == .hex("#A1B2C3"))
    }

    @Test
    func setColorReportsUnchangedStyleAsFalse() throws {
        let (paths, homeURL) = Self.makeRuntimePaths()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let store = AnnotationStyleStore(runtimePaths: paths)

        #expect(try store.setColor(.named(.amber), forKey: "pr"))
        #expect(try store.setColor(.named(.amber), forKey: "pr") == false)
        #expect(try store.setColor(.named(.red), forKey: "pr"))
    }

    @Test
    func runtimePathIsolationKeepsStoresIndependent() throws {
        let (firstPaths, firstHome) = Self.makeRuntimePaths()
        let (secondPaths, secondHome) = Self.makeRuntimePaths()
        defer {
            try? FileManager.default.removeItem(at: firstHome)
            try? FileManager.default.removeItem(at: secondHome)
        }
        let firstStore = AnnotationStyleStore(runtimePaths: firstPaths)
        let secondStore = AnnotationStyleStore(runtimePaths: secondPaths)

        #expect(try firstStore.setColor(.named(.violet), forKey: "pr"))

        #expect(secondStore.colorTokensByKey.isEmpty)
        #expect(AnnotationStyleStore(runtimePaths: secondPaths).colorTokensByKey.isEmpty)
    }

    @Test
    func corruptOrInvalidPersistedEntriesFallBackSafely() throws {
        let (paths, homeURL) = Self.makeRuntimePaths()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let fileURL = paths.configDirectoryURL
            .appending(path: AnnotationStyleStore.fileName, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try "not json at all {{{".write(to: fileURL, atomically: true, encoding: .utf8)
        #expect(AnnotationStyleStore(runtimePaths: paths).colorTokensByKey.isEmpty)

        try """
        {"pr": "green", "Bad Key": "red", "env": "not-a-color", "ok": "#0F0F0F"}
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = AnnotationStyleStore(runtimePaths: paths)
        #expect(store.colorTokensByKey == [
            "pr": .named(.green),
            "ok": .hex("#0F0F0F"),
        ])
    }

    @Test
    func failedPersistLeavesDiskAndObservedStateUnchanged() throws {
        let (paths, homeURL) = Self.makeRuntimePaths()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        // Occupy the runtime-home path with a regular FILE so creating the
        // config directory (and the style file inside it) must fail.
        try FileManager.default.createDirectory(
            at: homeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: homeURL.path, contents: Data())
        let store = AnnotationStyleStore(runtimePaths: paths)

        #expect(throws: (any Error).self) {
            try store.setColor(.named(.green), forKey: "pr")
        }
        #expect(store.colorTokensByKey.isEmpty)
        #expect(store.effectiveColorToken(forKey: "pr") == AnnotationStyleStore.fallbackColorToken(forKey: "pr"))
    }

    // MARK: - Observation

    @Test
    func colorChangesPublishExactlyWhenStyleActuallyChanges() throws {
        let (paths, homeURL) = Self.makeRuntimePaths()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let store = AnnotationStyleStore(runtimePaths: paths)
        var publishCount = 0
        let cancellable = store.objectWillChange.sink { _ in
            publishCount += 1
        }

        #expect(try store.setColor(.named(.blue), forKey: "pr"))
        #expect(publishCount == 1)

        // A no-op set publishes nothing, so chips are not re-rendered.
        #expect(try store.setColor(.named(.blue), forKey: "pr") == false)
        #expect(publishCount == 1)

        // A color-only change publishes and updates the effective token that
        // every rendered chip resolves through.
        #expect(try store.setColor(.hex("#123456"), forKey: "pr"))
        #expect(publishCount == 2)
        #expect(store.effectiveColorToken(forKey: "pr") == .hex("#123456"))
        _ = cancellable
    }
}
