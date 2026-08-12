import AppKit
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

        // The mapping must be a pure function of the key bytes.
        let keys = ["pr", "env", "build", "review", "deploy", "issue"]
        let firstRun = keys.map { AnnotationStyleStore.fallbackColorToken(forKey: $0) }
        let secondRun = keys.map { AnnotationStyleStore.fallbackColorToken(forKey: $0) }
        #expect(firstRun == secondRun)
    }

    @Test
    func automaticFallbacksAvoidReservedHuesAndDistinguishCommonKeys() throws {
        for index in 0..<512 {
            let token = AnnotationStyleStore.fallbackColorToken(forKey: "key-\(index)")
            guard case .hex = token else {
                Issue.record("automatic annotation colors must use generated hex tokens")
                return
            }
            let hueDegrees = try Self.hueDegrees(for: token)
            // Converting an 8-bit RGB token back to HSL can shift the source
            // hue by roughly two degrees at the range edges.
            #expect(hueDegrees >= 77)
            #expect(hueDegrees <= 303)
        }

        let semanticKeys = ["linear", "github-pr", "github-issue", "git-branch"]
        let semanticTokens = semanticKeys.map(AnnotationStyleStore.fallbackColorToken(forKey:))
        #expect(Set(semanticTokens).count == semanticTokens.count)

        let semanticHues = try semanticTokens.map(Self.hueDegrees(for:))
        for firstIndex in semanticHues.indices {
            for secondIndex in semanticHues.indices where secondIndex > firstIndex {
                #expect(abs(semanticHues[firstIndex] - semanticHues[secondIndex]) >= 20)
            }
        }
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

    private static func hueDegrees(for token: AnnotationColorToken) throws -> Double {
        guard case .hex(let value) = token,
              let rawValue = UInt32(value.dropFirst(), radix: 16) else {
            Issue.record("expected a valid generated hex token")
            return 0
        }
        let color = NSColor(
            calibratedRed: CGFloat((rawValue >> 16) & 0xFF) / 255,
            green: CGFloat((rawValue >> 8) & 0xFF) / 255,
            blue: CGFloat(rawValue & 0xFF) / 255,
            alpha: 1
        )
        let rgbColor = try #require(color.usingColorSpace(.deviceRGB))
        return Double(rgbColor.hueComponent) * 360
    }
}
