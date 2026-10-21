import CoreState
import Foundation
import Testing
import ToasttyNetworkShim
@testable import ToasttyAppLogic

/// Behavior checks for the Linux stand-ins under the App layer.
@MainActor
@Suite(.serialized)
struct LinuxShimTests {
    // MARK: QR code

    @Test(arguments: [
        "a",
        "toastty://pair?v=1",
        String(repeating: "x", count: 120),
        String(repeating: "Toastty pairing payload 0123456789/", count: 8),
    ])
    func qrSymbolsDecodeBackToTheirPayload(payload: String) throws {
        let symbol = try #require(QRCodeEncoder.encode(bytes: Array(payload.utf8)))
        #expect(symbol.size == symbol.version * 4 + 17)
        #expect(try QRSelfCheckDecoder.decode(symbol) == Array(payload.utf8))
    }

    @Test func qrVersionsAreTheSmallestThatFitAtLevelM() throws {
        // ISO 18004 byte-mode capacities at ECC M: v1 14, v2 26, v10 213.
        #expect(QRCodeEncoder.encode(bytes: Array(repeating: 65, count: 14))?.version == 1)
        #expect(QRCodeEncoder.encode(bytes: Array(repeating: 65, count: 15))?.version == 2)
        #expect(QRCodeEncoder.encode(bytes: Array(repeating: 65, count: 26))?.version == 2)
        #expect(QRCodeEncoder.encode(bytes: Array(repeating: 65, count: 213))?.version == 10)
        #expect(QRCodeEncoder.encode(bytes: Array(repeating: 65, count: 214))?.version == 11)
    }

    @Test func pairingQRImageIsAPNGWithQuietZone() throws {
        let image = try #require(RemoteAccessPairingQRCode.image(payload: "toastty-pairing-test", scale: 4))
        let bitmap = try #require(image.bitmap)
        #expect(bitmap.width == bitmap.height)
        // Top-left corner (quiet zone) is white; the finder pattern starts dark.
        #expect(bitmap.pixel(x: 0, y: 0) == (255, 255, 255, 255))
        let quiet = RemoteAccessPairingQRCode.quietZoneModules * 4
        #expect(bitmap.pixel(x: quiet, y: quiet) == (0, 0, 0, 255))
        let png = try #require(image.pngData)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(RemoteAccessPairingQRCode.image(payload: "") == nil)

        // Independent decoder check (scripts outside the repo read these):
        // QR_DUMP_DIR=<dir> writes sample codes and their payloads.
        if let directory = ProcessInfo.processInfo.environment["QR_DUMP_DIR"] {
            let samples = [
                "toastty-pairing-test",
                String(repeating: "Toastty pairing payload 0123456789/", count: 8),
            ]
            for (index, sample) in samples.enumerated() {
                let sampleImage = try #require(RemoteAccessPairingQRCode.image(payload: sample))
                try sampleImage.pngData?.write(to: URL(fileURLWithPath: "\(directory)/qr-\(index).png"))
                try Data(sample.utf8).write(to: URL(fileURLWithPath: "\(directory)/qr-\(index).txt"))
            }
        }
    }

    // MARK: Network shim

    @Test func listenerAndConnectionExchangeBytesAndReportPortInUse() async throws {
        let port = try LinuxTestSupport.freeLoopbackPort()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "shim-test")
        let ready = AsyncFlag()
        listener.stateUpdateHandler = { state in if state == .ready { ready.set() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                connection.send(content: Data("echo:".utf8) + (data ?? Data()), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
        try await ready.wait()
        #expect(listener.port?.rawValue == port)

        let client = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        client.start(queue: queue)
        client.send(content: Data("hello".utf8), completion: .contentProcessed { _ in })
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            client.receive(minimumIncompleteLength: 10, maximumLength: 1024) { data, _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) }
            }
        }
        #expect(String(decoding: reply, as: UTF8.self) == "echo:hello")
        client.cancel()

        // A second listener on the same port fails with EADDRINUSE, which the
        // gateway maps to its port-in-use recovery message.
        let failed = AsyncValue<NWError>()
        let second = try NWListener(using: parameters)
        second.stateUpdateHandler = { state in if case .failed(let error) = state { failed.set(error) } }
        second.start(queue: queue)
        let error = try await failed.wait()
        #expect(error == .posix(.EADDRINUSE))
        #expect(RemoteAccessListenerFailure(error) == .portInUse)
        listener.cancel()
    }

    // MARK: inotify-backed file observation

    @Test func filePathObserverSeesWritesAndAtomicReplacement() async throws {
        let directory = try LinuxTestSupport.makeTemporaryDirectory("fpo")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("doc.md")
        try "one".write(to: file, atomically: false, encoding: .utf8)
        let changes = AsyncCounter()
        let observer = FilePathObserver(path: file.path) { changes.increment() }
        defer { observer.invalidate() }

        try await Task.sleep(nanoseconds: 50_000_000)
        try "two, longer".write(to: file, atomically: false, encoding: .utf8)
        try await changes.wait(atLeast: 1)
        try "three".write(to: file, atomically: true, encoding: .utf8) // rename over
        try await changes.wait(atLeast: 2)
    }

    // MARK: Combine

    @Test func combineLatestEmitsTheLatestPairAfterBothUpstreamsEmit() {
        let left = PassthroughSubject<Int, Never>()
        let right = CurrentValueSubject<String, Never>("a")
        var received: [String] = []
        let cancellable = left.combineLatest(right).sink { received.append("\($0)\($1)") }
        right.send("b")
        #expect(received.isEmpty)
        left.send(1)
        right.send("c")
        left.send(2)
        #expect(received == ["1b", "1c", "2c"])
        cancellable.cancel()
        left.send(3)
        #expect(received.count == 3)
    }

    // MARK: Platform services

    @Test func headlessAlertsAnswerWithTheCancelButtonAndCarrySuppression() {
        let services = HeadlessLinuxPlatformServices()
        let previous = LinuxPlatform.services
        LinuxPlatform.install(services)
        defer { LinuxPlatform.install(previous) }

        let alert = NSAlert()
        alert.messageText = "Close this terminal?"
        alert.addConfiguredButton(withTitle: "Cancel", behavior: .cancelAction)
        alert.addConfiguredButton(withTitle: "Close", behavior: .defaultAction)
        #expect(alert.runModal() == .alertFirstButtonReturn)
        #expect(services.presentedAlerts.last?.buttons.map(\.title) == ["Cancel", "Close"])

        let quit = NSAlert()
        quit.addButton(withTitle: "Quit")
        quit.addButton(withTitle: "Cancel")
        quit.showsSuppressionButton = true
        services.alertResponder = { _ in 0 | LinuxAlertResponse.suppressionFlag }
        #expect(quit.runModal() == .alertFirstButtonReturn)
        #expect(quit.suppressionButton?.state == .on)

        var opened: [URL] = []
        services.urlOpener = { opened.append($0); return true }
        #expect(NSWorkspace.shared.open(URL(string: "https://example.com")!))
        #expect(opened.map(\.absoluteString) == ["https://example.com"])

        #expect(NSPasteboard.general.setString("copied", forType: .string))
        #expect(NSPasteboard.general.string(forType: .string) == "copied")
    }

    @Test func systemNotificationsDeliverThroughPlatformServicesAndRouteActivation() async throws {
        let services = HeadlessLinuxPlatformServices()
        let previous = LinuxPlatform.services
        LinuxPlatform.install(services)
        defer {
            LinuxPlatform.install(previous)
            SystemNotificationSender.resetForTesting()
        }
        SystemNotificationSender.resetForTesting()
        let workspaceID = UUID()
        let panelID = UUID()
        await SystemNotificationSender.send(title: "Claude Code", body: "Ready", workspaceID: workspaceID, panelID: panelID)
        let delivered = try #require(services.deliveredNotifications.last)
        #expect(delivered.title.isEmpty == false)
        #expect(delivered.userInfo[DesktopNotificationUserInfoKey.panelID] == panelID.uuidString)
        #expect(delivered.userInfo[DesktopNotificationUserInfoKey.workspaceID] == workspaceID.uuidString)

        services.notificationAuthorizationState = .denied
        await SystemNotificationSender.send(title: "Denied", body: "x", workspaceID: nil, panelID: nil)
        #expect(services.deliveredNotifications.count == 1)
    }

    @Test func mainQueueHandleIsAvailableForGLibIntegration() {
        #expect(LinuxMainLoopIntegration.isAvailable)
        // The test runner already parked the main thread in dispatchMain(),
        // so there is no runloop handle to drain here.
        _ = LinuxMainLoopIntegration.serviceRunLoop()
    }

    // MARK: UserDefaults

    /// corelibs `UserDefaults` only reaches disk on `synchronize()`; the app's
    /// defaults write every change through, so preferences survive a restart.
    /// Checked on the plist file: a new `UserDefaults` in this process would
    /// read the in-memory cache.
    @Test func appDefaultsWriteSettingsThroughToTheirPlist() throws {
        var environment = ProcessInfo.processInfo.environment
        environment["TOASTTY_RUNTIME_HOME"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-defaults-\(UUID().uuidString)").path
        let suiteName = try #require(
            ToasttyRuntimePaths.resolve(homeDirectoryPath: NSHomeDirectory(), environment: environment).userDefaultsSuiteName
        )
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? NSHomeDirectory() + "/.config"
        let plist = URL(fileURLWithPath: configHome).appendingPathComponent("\(suiteName).plist")
        defer { try? FileManager.default.removeItem(at: plist) }
        let defaults = ToasttyAppDefaults.make(environment: environment)
        func onDisk() throws -> [String: Any] {
            let data = try Data(contentsOf: plist)
            return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }

        RemoteAccessPreferences.persistEnabled(true, userDefaults: defaults)
        RemoteAccessPreferences.persistTailnetOrigin("https://host.example.ts.net", userDefaults: defaults)
        ToasttySettingsStore.persistAskBeforeQuitting(false, userDefaults: defaults)
        var stored = try onDisk()
        #expect(stored["toastty.remoteAccess.enabled"] as? Bool == true)
        #expect(stored["toastty.remoteAccess.tailnetOrigin"] as? String == "https://host.example.ts.net")
        #expect(stored["toastty.askBeforeQuitting"] as? Bool == false)

        RemoteAccessPreferences.persistEnabled(false, userDefaults: defaults)
        RemoteAccessPreferences.persistTailnetOrigin(nil, userDefaults: defaults)
        stored = try onDisk()
        #expect(stored["toastty.remoteAccess.enabled"] as? Bool == false)
        #expect(stored["toastty.remoteAccess.tailnetOrigin"] == nil)
    }

    @Test func screenAndWindowProxiesReflectPlatformSnapshots() {
        let services = HeadlessLinuxPlatformServices()
        let previous = LinuxPlatform.services
        LinuxPlatform.install(services)
        defer { LinuxPlatform.install(previous) }
        let windowID = UUID()
        services.windows = [LinuxWindowSnapshot(id: windowID, frame: CGRect(x: 10, y: 20, width: 800, height: 600), isKey: true)]
        #expect(NSApp.keyWindow?.windowID == windowID)
        #expect(NSApp.windows.first?.identifier?.rawValue == windowID.uuidString)
        services.screens = [LinuxScreenSnapshot(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), scale: 2)]
        #expect(NSScreen.main?.backingScaleFactor == 2)
        #expect(NSScreen.screens.first === NSScreen.main)
    }

    @Test func relativeDateFormatterMatchesDarwinEnglishOutput() {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(formatter.localizedString(for: now.addingTimeInterval(-300), relativeTo: now) == "5 min. ago")
        #expect(formatter.localizedString(for: now.addingTimeInterval(-7_200), relativeTo: now) == "2 hr. ago")
        #expect(formatter.localizedString(for: now.addingTimeInterval(-86_400 * 3), relativeTo: now) == "3 days ago")
    }
}

// MARK: - Async helpers

private final class AsyncFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    func set() { lock.withLock { isSet = true } }
    func wait(timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while lock.withLock({ isSet }) == false {
            guard Date() < deadline else { throw LinuxTestSupport.Failure.timedOut("flag") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class AsyncValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    func set(_ value: Value) { lock.withLock { self.value = value } }
    func wait(timeout: TimeInterval = 5) async throws -> Value {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let value = lock.withLock({ value }) { return value }
            guard Date() < deadline else { throw LinuxTestSupport.Failure.timedOut("value") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class AsyncCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    func wait(atLeast target: Int, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while lock.withLock({ count }) < target {
            guard Date() < deadline else { throw LinuxTestSupport.Failure.timedOut("\(target) file changes") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - QR self-check decoder

/// Reads a symbol back like a scanner would: format bits (BCH-checked),
/// unmasking, zigzag codeword extraction, de-interleaving, Reed-Solomon
/// syndrome check of every block, then the byte-mode segment.
enum QRSelfCheckDecoder {
    enum Failure: Error { case formatBits, syndrome(Int), segment }

    static func decode(_ symbol: QRCodeSymbol) throws -> [UInt8] {
        let size = symbol.size
        let version = symbol.version
        // Format bits, first copy, as drawn by the encoder.
        var raw = 0
        func bitAt(_ x: Int, _ y: Int) -> Int { symbol.modules[y][x] ? 1 : 0 }
        let positions: [(Int, Int)] = (0...5).map { (8, $0) } + [(8, 7), (8, 8), (7, 8)] + (9..<15).map { (14 - $0, 8) }
        for (index, position) in positions.enumerated() {
            raw |= bitAt(position.0, position.1) << index
        }
        let unmasked = raw ^ 0x5412
        let data = unmasked >> 10
        var remainder = data
        for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
        guard (data << 10 | remainder) == unmasked, data >> 3 == 0 /* level M */ else { throw Failure.formatBits }
        let mask = data & 7
        #expect(mask == symbol.mask)

        // Function-pattern map, rebuilt independently of the encoder state.
        var isFunction = Array(repeating: Array(repeating: false, count: size), count: size)
        func mark(_ x: Int, _ y: Int) { if (0..<size).contains(x), (0..<size).contains(y) { isFunction[y][x] = true } }
        for i in 0..<size { mark(6, i); mark(i, 6) }
        for (cx, cy) in [(3, 3), (size - 4, 3), (3, size - 4)] {
            for dy in -4...4 { for dx in -4...4 { mark(cx + dx, cy + dy) } }
        }
        var alignment: [Int] = []
        if version > 1 {
            let count = version / 7 + 2
            let step = (version * 8 + count * 3 + 5) / (count * 4 - 4) * 2
            alignment = ((0..<(count - 1)).map { size - 7 - $0 * step } + [6]).reversed()
        }
        for (i, ax) in alignment.enumerated() {
            for (j, ay) in alignment.enumerated() {
                let last = alignment.count - 1
                if (i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0) { continue }
                for dy in -2...2 { for dx in -2...2 { mark(ax + dx, ay + dy) } }
            }
        }
        for i in 0..<9 { mark(8, i); mark(i, 8) }
        for i in 0..<8 { mark(size - 1 - i, 8); mark(8, size - 1 - i) }
        if version >= 7 {
            for i in 0..<18 { mark(size - 11 + i % 3, i / 3); mark(i / 3, size - 11 + i % 3) }
        }

        func maskBit(_ x: Int, _ y: Int) -> Bool {
            switch mask {
            case 0: (x + y) % 2 == 0
            case 1: y % 2 == 0
            case 2: x % 3 == 0
            case 3: (x + y) % 3 == 0
            case 4: (x / 3 + y / 2) % 2 == 0
            case 5: x * y % 2 + x * y % 3 == 0
            case 6: (x * y % 2 + x * y % 3) % 2 == 0
            default: ((x + y) % 2 + x * y % 3) % 2 == 0
            }
        }
        var bits: [Bool] = []
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vertical in 0..<size {
                for offset in 0..<2 {
                    let x = right - offset
                    let upward = ((right + 1) & 2) == 0
                    let y = upward ? size - 1 - vertical : vertical
                    if isFunction[y][x] == false {
                        bits.append(symbol.modules[y][x] != maskBit(x, y))
                    }
                }
            }
            right -= 2
        }
        let rawCodewordCount = QRCodeEncoder.rawDataModuleCount(version: version) / 8
        var codewords = [UInt8](repeating: 0, count: rawCodewordCount)
        for i in 0..<(rawCodewordCount * 8) where bits[i] {
            codewords[i >> 3] |= UInt8(1 << (7 - (i & 7)))
        }

        // De-interleave (ECC M tables) and verify each block's syndromes.
        let eccPerBlock = [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26][version]
        let blockCount = [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16][version]
        let shortCount = blockCount - rawCodewordCount % blockCount
        let shortLength = rawCodewordCount / blockCount
        var blocks = (0..<blockCount).map { _ in [UInt8]() }
        var cursor = 0
        for column in 0..<(shortLength + 1) {
            for block in 0..<blockCount {
                if column == shortLength - eccPerBlock && block < shortCount { continue }
                blocks[block].append(codewords[cursor])
                cursor += 1
            }
        }
        var dataCodewords: [UInt8] = []
        for (index, block) in blocks.enumerated() {
            for power in 0..<eccPerBlock {
                // Evaluate the block polynomial at alpha^power.
                var root: UInt8 = 1
                for _ in 0..<power { root = gfMultiply(root, 2) }
                var value: UInt8 = 0
                for byte in block { value = gfMultiply(value, root) ^ byte }
                guard value == 0 else { throw Failure.syndrome(index) }
            }
            dataCodewords += block.dropLast(eccPerBlock)
        }

        // Byte-mode segment.
        var reader = (bytes: dataCodewords, position: 0)
        func read(_ count: Int) -> Int {
            var value = 0
            for _ in 0..<count {
                let byte = reader.bytes[reader.position >> 3]
                value = value << 1 | Int((byte >> (7 - UInt8(reader.position & 7))) & 1)
                reader.position += 1
            }
            return value
        }
        guard read(4) == 0b0100 else { throw Failure.segment }
        let length = read(version <= 9 ? 8 : 16)
        return (0..<length).map { _ in UInt8(read(8)) }
    }

    private static func gfMultiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for shift in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((Int(y) >> shift) & 1) * Int(x)
        }
        return UInt8(z & 0xFF)
    }
}
