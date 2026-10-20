import Foundation
import XCTest
import ToasttyMobileDomain
@testable import ToasttyMobileApp

final class ToasttyDiagnosticReportTests: XCTestCase {
    func testConcurrentCallbacksAndHandlerAttachmentPersistTheNewestCompleteCounts() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = makeRecorder(directory)
        let receiver = ToasttyPushReceiverDiagnostics()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index.isMultiple(of: 10) {
                receiver.installHandler { recorder.updateReceiverSnapshot($0) }
            }
            receiver.beginCallback(.foreground)
            receiver.decodedCallback(.foreground, payload: nil)
        }
        await assertFlush(recorder)
        let final = try readReport(directory).receiver
        XCTAssertEqual(final?.sequence, receiver.snapshot.sequence)
        XCTAssertEqual(final?.foreground, receiver.snapshot.foreground)
        XCTAssertEqual(final?.foreground.entered, 200)
        XCTAssertEqual(final?.foreground.malformed, 200)
    }

    func testReceiverUpdatesPreserveOtherStateAndRejectLateOlderCounters() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = makeRecorder(directory)
        let receiver = ToasttyPushReceiverDiagnostics()
        receiver.beginCallback(.foreground)
        let older = receiver.snapshot
        receiver.beginCallback(.foreground)
        let newer = receiver.snapshot
        recorder.updateReceiverSnapshot(newer)
        recorder.updateReceiverSnapshot(older)
        var log = ToasttyConnectionDiagnosticLog()
        log.append(.streamConnected)
        let push = snapshot(sequence: 1, reason: .awaitingProof)
        recorder.updatePushSnapshot(push, log: log)
        await assertFlush(recorder)
        let report = try readReport(directory)
        XCTAssertEqual(report.receiver?.foreground.entered, 2)
        XCTAssertEqual(report.receiver?.sequence, newer.sequence)
        XCTAssertEqual(report.push, push)
        XCTAssertEqual(report.events.map(\.event), ["connected"])
    }

    func testInitialReportAndBurstPersistTheFinalBoundedRing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = makeRecorder(directory)
        await assertFlush(recorder)
        var report = try readReport(directory)
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertTrue(report.events.isEmpty)
        XCTAssertEqual(report.app.bundleID, "test.toastty")
        XCTAssertEqual(report.app.version, "1.2")
        XCTAssertEqual(report.app.build, "34")

        var log = ToasttyConnectionDiagnosticLog()
        for index in 0..<200 {
            log.append(.gatewayRequestSucceeded, recordedAt: Date(timeIntervalSince1970: Double(index)))
            recorder.submit(log: log)
        }
        await assertFlush(recorder)
        report = try readReport(directory)
        XCTAssertEqual(report.events.count, 128)
        XCTAssertEqual(report.events.first?.sequence, 72)
        XCTAssertEqual(report.events.last?.sequence, 199)
        XCTAssertEqual(report.events.last?.recordedAt, Date(timeIntervalSince1970: 199))
        XCTAssertEqual(report.lastFlushReason, .explicit)
    }

    func testSnapshotUpdatesAndHistoricalReturnsUseOnlyTheSafeProjection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = makeRecorder(directory)
        var log = ToasttyConnectionDiagnosticLog()
        let first = snapshot(sequence: 1, reason: .disconnected)
        log.append(.pushSetupReturned, pushSnapshot: first)
        recorder.updatePushSnapshot(first, log: log)
        let final = snapshot(sequence: 2, reason: .relayCooldown)
        log.append(.pushSetupReturned, pushSnapshot: final)
        recorder.updatePushSnapshot(final, log: log)
        await assertFlush(recorder)
        let report = try readReport(directory)
        XCTAssertEqual(report.push, final)
        XCTAssertEqual(report.events.map(\.pushSnapshot), [first, final])
        let data = try Data(contentsOf: directory.appendingPathComponent("current.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let push = try XCTUnwrap(json["push"] as? [String: Any])
        XCTAssertEqual(Set(push.keys), ["stage", "foreground", "connected", "desired", "tokenPresent",
            "configurationMatches", "reconciling", "activeRegistrationEnabled", "permission", "cleanupCount", "lastAction",
            "lastReturnReason", "lastReturnAt", "resultSequence"])
    }

    func testProjectionIsBoundedEvenWhenCallerSuppliesALargerRing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = makeRecorder(directory)
        var log = ToasttyConnectionDiagnosticLog(capacity: 256)
        for _ in 0..<200 { log.append(.streamConnected) }
        recorder.submit(log: log)
        await assertFlush(recorder)
        XCTAssertEqual(try readReport(directory).events.count, 128)
    }

    func testScheduledWriteIncludesTheLastStateWithoutAnExplicitFlush() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = makeRecorder(directory, interval: 0.02)
        var log = ToasttyConnectionDiagnosticLog()
        log.append(.streamConnecting)
        recorder.submit(log: log)
        log.append(.streamConnected)
        recorder.submit(log: log)
        let deadline = Date.now.addingTimeInterval(2)
        while (try? readReport(directory).events.count) != 2, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let report = try readReport(directory)
        XCTAssertEqual(report.events.map(\.event), ["connecting", "connected"])
        XCTAssertEqual(report.lastFlushReason, .coalesced)
    }

    func testEachProcessRetainsThePriorRunWithoutRotatingOnEachWrite() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = makeRecorder(directory)
        await assertFlush(first)
        let firstRun = try readReport(directory).runID

        let second = makeRecorder(directory)
        await assertFlush(second)
        let secondRun = try readReport(directory).runID
        XCTAssertNotEqual(secondRun, firstRun)
        XCTAssertEqual(try readReport(directory, name: "previous.json").runID, firstRun)
        var log = ToasttyConnectionDiagnosticLog()
        log.append(.authStarted)
        second.submit(log: log)
        await assertFlush(second)
        XCTAssertEqual(try readReport(directory, name: "previous.json").runID, firstRun)

        let third = makeRecorder(directory)
        await assertFlush(third)
        XCTAssertEqual(try readReport(directory, name: "previous.json").runID, secondRun)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       ["current.json", "previous.json"])
    }

    func testSafeEventProjectionHasOnlyAllowlistedFields() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = makeRecorder(directory)
        var log = ToasttyConnectionDiagnosticLog()
        log.append(.pushRateLimited, pushDetails: ToasttyPushDiagnosticDetails(
            registrationNumber: 4,
            relay: PushRelayDiagnostic(statusCode: 429, code: .verificationTokenLimit,
                                      rateLimitSource: .relay, providerRefreshAttempted: true),
            retryAfter: 3.1
        ))
        recorder.submit(log: log)
        await assertFlush(recorder)
        let data = try Data(contentsOf: directory.appendingPathComponent("current.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let details = try XCTUnwrap(events.first?["pushDetails"] as? [String: Any])
        XCTAssertEqual(Set(details.keys), ["registrationNumber", "statusCode", "code",
                                         "rateLimitSource", "providerRefreshAttempted", "retryAfterSeconds"])
        XCTAssertEqual(details["retryAfterSeconds"] as? Int, 4)
        XCTAssertEqual(details["code"] as? String, "verification_token_limit")
        XCTAssertEqual(Set(try XCTUnwrap(events.first).keys), ["sequence", "recordedAt", "event", "pushDetails"])
        XCTAssertNil(json["credentials"])
        XCTAssertNil(json["state"])
        XCTAssertNil(json["error"])
    }

    func testFailedWriteIsNonfatalAndCanRetryWithoutLosingPriorEvidence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = makeRecorder(directory)
        await assertFlush(first)
        let firstData = try Data(contentsOf: directory.appendingPathComponent("current.json"))
        // A directory at the destination prevents the next run from rotating.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("previous.json"),
                                               withIntermediateDirectories: false)
        let second = makeRecorder(directory)
        await assertFlush(second, succeeds: false)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("current.json")), firstData)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("previous.json"))
        await assertFlush(second)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("previous.json")), firstData)
    }

    func testFullyPopulatedSnapshotRingFitsTheCollectorByteLimit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = makeRecorder(directory)
        let push = fullSnapshot()
        var receiver = ToasttyPushReceiverSnapshot()
        receiver.capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        receiver.settings = .init(authorizationStatus: .authorized, alert: .enabled,
            lockScreen: .enabled, notificationCenter: .enabled)
        receiver.delegate = .init(identity: .expected, foregroundSelector: true, responseSelector: true)
        receiver.foreground = .init(entered: .max, verification: .max, session: .max, malformed: .max, ignored: .max)
        receiver.response = receiver.foreground
        receiver.firstRecovery = .init(capturedAt: receiver.capturedAt, referenceAt: receiver.capturedAt, referenceKind: .requestStarted,
            hasPendingRegistration: true, hasPairing: true, raw: 99999, verification: 99999, session: 99999,
            malformed: 99999, matchingRegistration: 99999, matchingPairing: 99999, matchingBoth: 99999,
            beforeReference: 99999, atOrAfterReference: 99999, withoutReference: 99999,
            verificationAtOrAfterReference: 99999)
        receiver.latestRecovery = receiver.firstRecovery
        recorder.updateReceiverSnapshot(receiver)
        var log = ToasttyConnectionDiagnosticLog()
        for _ in 0..<128 {
            log.append(.pushSetupReturned, pushDetails: fullPushDetails(), pushSnapshot: push)
        }
        recorder.updatePushSnapshot(push, log: log)
        await assertFlush(recorder)
        let data = try Data(contentsOf: directory.appendingPathComponent("current.json"))
        XCTAssertLessThanOrEqual(data.count, ToasttyDiagnosticRecorder.maximumReportBytes)
        let report = try readReport(directory)
        XCTAssertEqual(report.events.count, 128)
        XCTAssertEqual(report.truncatedCount, 0)
        XCTAssertEqual(report.push, push)
        XCTAssertEqual(report.receiver, receiver)
    }

    func testByteBudgetDropsOldestEventsAndKeepsCurrentSnapshot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ToasttyDiagnosticRecorder(directoryURL: directory,
            app: .init(bundleID: "test.toastty", version: "1", build: "1"),
            coalescingInterval: 60, byteBudget: 3_000)
        let push = fullSnapshot()
        var log = ToasttyConnectionDiagnosticLog()
        for _ in 0..<128 { log.append(.pushSetupReturned, pushSnapshot: push) }
        recorder.updatePushSnapshot(push, log: log)
        await assertFlush(recorder)
        let data = try Data(contentsOf: directory.appendingPathComponent("current.json"))
        XCTAssertLessThanOrEqual(data.count, 3_000)
        let report = try readReport(directory)
        XCTAssertGreaterThan(report.truncatedCount, 0)
        XCTAssertEqual(report.events.count + report.truncatedCount, 128)
        XCTAssertEqual(report.events.last?.sequence, 127)
        XCTAssertEqual(report.push, push)
    }

    func testBackgroundGraceWritesLateCallbacksWithoutWaitingForCoalescing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = makeRecorder(directory)
        var log = ToasttyConnectionDiagnosticLog()
        log.append(.streamConnected)
        recorder.submit(log: log)
        let background = Task { await recorder.flushBackgroundChanges(gracePeriod: .milliseconds(100)) }
        let deadline = Date.now.addingTimeInterval(2)
        while (try? readReport(directory).events.count) != 1, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        log.append(.streamDisconnected)
        recorder.submit(log: log)
        let succeeded = await background.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(try readReport(directory).events.map(\.event), ["connected", "disconnected"])
        XCTAssertEqual(try readReport(directory).lastFlushReason, .background)
    }

    func testNoisySubmissionsKeepTheLatestRingAndPushSnapshot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = makeRecorder(directory, interval: 0.001)
        let push = fullSnapshot()
        var log = ToasttyConnectionDiagnosticLog()
        recorder.updatePushSnapshot(push, log: log)
        for _ in 0..<10_000 {
            log.append(.gatewayRequestSucceeded)
            recorder.submit(log: log)
        }
        await assertFlush(recorder)
        let report = try readReport(directory)
        XCTAssertEqual(report.events.last?.sequence, 9_999)
        XCTAssertEqual(report.events.count, 128)
        XCTAssertEqual(report.push, push)
    }

    private func fullPushDetails() -> ToasttyPushDiagnosticDetails {
        ToasttyPushDiagnosticDetails(registrationNumber: .max,
            relay: PushRelayDiagnostic(statusCode: 429, code: .verificationGlobalLimit,
                rateLimitSource: .unidentified, providerRefreshAttempted: true), retryAfter: 86_400)
    }

    private func fullSnapshot() -> ToasttyPushSetupSnapshot {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return ToasttyPushSetupSnapshot(stage: .awaitingProof, foreground: true, reconciling: true,
            activeRegistrationEnabled: true, permission: .allowed, connected: true, desired: true,
            tokenPresent: true, configurationMatches: true, savedCooldownUntil: date, cooldownUntil: date,
            retryScheduledAt: date, cleanupCount: .max, lastAction: .reconcile,
            lastReturnReason: .configurationUnavailable, lastReturnAt: date, resultSequence: .max)
    }

    private func snapshot(sequence: UInt64, reason: ToasttyPushSetupSnapshot.ReturnReason) -> ToasttyPushSetupSnapshot {
        ToasttyPushSetupSnapshot(stage: .idle, foreground: true, reconciling: false,
            activeRegistrationEnabled: false, permission: .allowed, connected: false, desired: true,
            tokenPresent: true, configurationMatches: true, savedCooldownUntil: nil, cooldownUntil: nil,
            retryScheduledAt: nil, cleanupCount: 0, lastAction: .reconcile,
            lastReturnReason: reason, lastReturnAt: Date(timeIntervalSince1970: 100), resultSequence: sequence)
    }

    private func assertFlush(_ recorder: ToasttyDiagnosticRecorder, succeeds: Bool = true,
                             file: StaticString = #filePath, line: UInt = #line) async {
        let result = await recorder.flush()
        XCTAssertEqual(result, succeeds, file: file, line: line)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeRecorder(_ directory: URL, interval: TimeInterval = 60) -> ToasttyDiagnosticRecorder {
        ToasttyDiagnosticRecorder(directoryURL: directory,
            app: .init(bundleID: "test.toastty", version: "1.2", build: "34"),
            coalescingInterval: interval)
    }

    private func readReport(_ directory: URL, name: String = "current.json") throws -> ToasttyDiagnosticReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ToasttyDiagnosticReport.self,
                                  from: Data(contentsOf: directory.appendingPathComponent(name)))
    }
}
