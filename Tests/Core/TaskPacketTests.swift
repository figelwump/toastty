import CoreState
import Foundation
import Testing

struct TaskPacketTests {
    private func draft(_ json: String) throws -> TaskPacket {
        try TaskPacket.parseDraft(Data(json.utf8))
    }

    private func refusal(_ json: String) -> String? {
        do {
            _ = try draft(json)
            return nil
        } catch let error as TaskPacketError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    @Test
    func aCompletePacketReadsAsWritten() throws {
        let packet = try draft("""
        {
          "summary": " Moves the totals above payment. ",
          "look_at": "The pinned totals bar at 390px",
          "checks": [{ "name": "npm test", "ok": true, "log": "/tmp/test.log" }, { "name": "e2e", "ok": false }],
          "not_verified": ["Safari sticky footer"],
          "screenshots": [
            { "name": "before-390", "pair": "before", "width": 390 },
            { "name": "after-390", "pair": "after", "width": 390 },
            { "name": "menu", "pair": null }
          ]
        }
        """)
        #expect(packet.summary == "Moves the totals above payment.")
        #expect(packet.lookAt == "The pinned totals bar at 390px")
        #expect(packet.checks == [.init(name: "npm test", ok: true, log: "/tmp/test.log"), .init(name: "e2e", ok: false)])
        #expect(packet.notVerified == ["Safari sticky footer"])
        #expect(packet.screenshots == [
            .init(name: "before-390", pair: .before, width: 390),
            .init(name: "after-390", pair: .after, width: 390),
            .init(name: "menu"),
        ])
    }

    @Test
    func notVerifiedMustBeWrittenOutButMayBeEmpty() throws {
        #expect(try draft(#"{"summary": "s", "look_at": "l", "not_verified": []}"#).notVerified == [])
        #expect(refusal(#"{"summary": "s", "look_at": "l"}"#)
            == "The packet needs not_verified: what you did not check, or [] when you checked everything.")
        #expect(refusal(#"{"summary": "s", "look_at": "l", "not_verified": "nothing"}"#) == "not_verified must be a list of strings.")
    }

    @Test
    func incompleteOrMistypedPacketsAreRefused() {
        let cases: [(String, String)] = [
            (#"{"summary": "s", "not_verified": []}"#, "The packet needs look_at as non-empty text."),
            (#"{"summary": "s", "look_at": "  ", "not_verified": []}"#, "The packet needs look_at as non-empty text."),
            (#"{"look_at": "l", "not_verified": []}"#, "The packet needs summary as non-empty text."),
            (#"{"summary": "s", "lookAt": "l", "not_verified": []}"#,
             "The packet has an unknown key \"lookAt\"; expected checks, look_at, not_verified, screenshots, summary."),
            (#"{"summary": "s", "look_at": "l", "not_verified": [], "version": 3}"#,
             "The packet has an unknown key \"version\"; expected checks, look_at, not_verified, screenshots, summary."),
            (#"{"summary": "s", "look_at": "l", "not_verified": [], "checks": [{"name": "t", "ok": 1}]}"#,
             "Check \"t\" needs ok: true or false."),
            (#"{"summary": "s", "look_at": "l", "not_verified": [], "checks": [{"name": "t", "ok": true, "passed": true}]}"#,
             "A check has an unknown key \"passed\"; expected name, ok, log."),
            (#"{"summary": "s", "look_at": "l", "not_verified": [], "screenshots": [{"name": "a", "pair": "left"}]}"#,
             "Screenshot \"a\" has pair left; expected \"before\", \"after\" or null."),
            (#"{"summary": "s", "look_at": "l", "not_verified": [], "screenshots": [{"name": "a"}, {"name": "a"}]}"#,
             "Two screenshots are named \"a\"."),
            (#"{"summary": "s", "look_at": "l", "not_verified": [], "screenshots": [{"name": "../a"}]}"#,
             "Each screenshot needs a name of letters, digits, '.', '_' or '-', at most 64 characters."),
            (#"{"summary": "s", "look_at": "l", "not_verified": [], "screenshots": [{"name": "a", "width": 0}]}"#,
             "Screenshot \"a\" needs width as a whole number of points from 1 to 10000."),
            (#"{"summary": "s", "look_at": "l", "not_verified": [], "screenshots": [{"name": "a", "width": true}]}"#,
             "Screenshot \"a\" needs width as a whole number of points from 1 to 10000."),
            ("[]", "The packet must be a JSON object."),
            ("not json", "The packet must be a JSON object."),
        ]
        for (json, message) in cases {
            #expect(refusal(json) == message, "\(json)")
        }
    }

    @Test
    func screenshotsMatchTheGivenFilesByName() throws {
        let packet = try draft("""
        {"summary": "s", "look_at": "l", "not_verified": [],
         "screenshots": [{"name": "before-390", "pair": "before", "width": 390}, {"name": "after-390", "pair": "after", "width": 390}]}
        """)
        let sizes = ["/s/before-390.png": 10, "/s/after-390.PNG": 20, "/s/other.png": 5, "/s/huge.png": TaskPacket.maximumScreenshotBytes + 1]
        func match(_ files: [String]) throws -> [String] {
            try packet.matchScreenshots(files: files) { sizes[$0] }.map(\.path)
        }
        func refusal(_ files: [String]) -> String? {
            do {
                _ = try match(files)
                return nil
            } catch {
                return (error as? TaskPacketError)?.message
            }
        }

        #expect(try match(["/s/after-390.PNG", "/s/before-390.png"]) == ["/s/before-390.png", "/s/after-390.PNG"])
        #expect(refusal(["/s/before-390.png"]) == "Screenshot \"after-390\" needs a file: pass --screenshot after-390.png.")
        #expect(refusal(["/s/before-390.png", "/s/after-390.PNG", "/s/other.png"])
            == "Screenshot /s/other.png is not named in the packet's screenshots.")
        #expect(refusal(["/s/before-390.png", "/missing/after-390.png"])
            == "Screenshot /missing/after-390.png does not exist or is not a readable file.")
        #expect(refusal(["/s/before-390.txt"]) == "Screenshot /s/before-390.txt must be a gif, jpeg, jpg, png, webp file.")
        #expect(refusal(["/s/before-390.png", "/t/before-390.jpg"]) == "Two screenshot files are named before-390.")

        let one = try draft(#"{"summary": "s", "look_at": "l", "not_verified": [], "screenshots": [{"name": "huge"}]}"#)
        #expect(throws: TaskPacketError("Screenshot /s/huge.png is larger than 20 MB.")) {
            try one.matchScreenshots(files: ["/s/huge.png"]) { sizes[$0] }
        }
    }

    @Test
    func eachPublishStoresTheNextVersionWithItsScreenshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toastty-packets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("after-390.PNG")
        try Data("png".utf8).write(to: image)
        let store = TaskPacketStore(rootURL: root.appendingPathComponent("task-packets", isDirectory: true))
        let taskID = UUID()
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let packet = TaskPacket(
            summary: "s",
            lookAt: "l",
            notVerified: [],
            screenshots: [.init(name: "after-390", pair: .after, width: 390)],
            createdAt: created,
            headCommit: "abc"
        )

        #expect(throws: TaskPacketError("The task has no packet.")) { try store.read(taskID: taskID) }
        let first = try store.write(packet, taskID: taskID, screenshots: [(packet.screenshots[0], image.path)], atLeastAfter: nil)
        #expect(first.version == 1)
        #expect(first.taskID == taskID)
        #expect(first.screenshots.map(\.file) == ["after-390.png"])
        let copy = store.versionDirectoryURL(taskID: taskID, version: 1).appendingPathComponent("after-390.png")
        #expect(FileManager.default.contents(atPath: copy.path) == Data("png".utf8))

        var revised = packet
        revised.summary = "s2"
        revised.screenshots = []
        let second = try store.write(revised, taskID: taskID, screenshots: [], atLeastAfter: 1)
        #expect(second.version == 2)
        // A version the record saw but the disk lost is never reused.
        #expect(try store.write(revised, taskID: taskID, screenshots: [], atLeastAfter: 5).version == 6)
        #expect(store.versions(taskID: taskID) == [1, 2, 6])

        #expect(try store.read(taskID: taskID).version == 6)
        let read = try store.read(taskID: taskID, version: 1)
        #expect(read == first)
        #expect(read.createdAt == created)
        #expect(try store.read(taskID: taskID, version: 2).summary == "s2")
        #expect(throws: TaskPacketError("The task has no packet v3.")) { try store.read(taskID: taskID, version: 3) }

        // The stored file keeps the agent's key names, with pair written out.
        let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store
            .versionDirectoryURL(taskID: taskID, version: 1)
            .appendingPathComponent(TaskPacketStore.packetFileName))) as? [String: Any])
        #expect(Set(stored.keys) == ["summary", "look_at", "checks", "not_verified", "screenshots", "task_id", "version", "created_at", "head_commit"])
    }

    @Test
    func aPacketIsStaleOnlyWhenTheWorktreeMovedPastItsCommit() {
        #expect(TaskPacket.isStale(headCommit: "abc", currentHead: "def"))
        #expect(TaskPacket.isStale(headCommit: "abc", currentHead: "abc") == false)
        #expect(TaskPacket.isStale(headCommit: nil, currentHead: "def") == false)
        #expect(TaskPacket.isStale(headCommit: "abc", currentHead: nil) == false)

        var record = TaskRecord(createdAt: Date(), text: "t", title: "t", slug: "t", source: .cli)
        record.packetHeadCommit = "abc"
        #expect(record.packetIsStale(currentHead: "def") == false)
        record.packetVersion = 1
        #expect(record.packetIsStale(currentHead: "def"))
    }
}
