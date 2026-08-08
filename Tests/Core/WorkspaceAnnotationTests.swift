import CoreState
import Foundation
import Testing

struct WorkspaceAnnotationValidationTests {
    @Test
    func canonicalKeyTrimsLowercasesAndValidates() {
        #expect(WorkspaceAnnotation.canonicalKey("  PR ") == "pr")
        #expect(WorkspaceAnnotation.canonicalKey("build.status_2-a") == "build.status_2-a")
        #expect(WorkspaceAnnotation.canonicalKey("MiXeD") == "mixed")

        #expect(WorkspaceAnnotation.canonicalKey("") == nil)
        #expect(WorkspaceAnnotation.canonicalKey("   ") == nil)
        #expect(WorkspaceAnnotation.canonicalKey("has space") == nil)
        #expect(WorkspaceAnnotation.canonicalKey("emoji🙂") == nil)
        #expect(WorkspaceAnnotation.canonicalKey("slash/key") == nil)
        #expect(WorkspaceAnnotation.canonicalKey(String(repeating: "a", count: 33)) == nil)
        #expect(WorkspaceAnnotation.canonicalKey(String(repeating: "a", count: 32)) != nil)
    }

    @Test
    func normalizedTextTrimsAndAppliesNFC() {
        #expect(WorkspaceAnnotation.normalizedText("  PR #4512  ") == "PR #4512")
        // Decomposed e + combining acute normalizes to the precomposed form.
        #expect(WorkspaceAnnotation.normalizedText("caf\u{0065}\u{0301}") == "café")
    }

    @Test
    func normalizedTextEnforcesUserPerceivedCharacterLimit() {
        #expect(WorkspaceAnnotation.normalizedText(String(repeating: "x", count: 80)) != nil)
        #expect(WorkspaceAnnotation.normalizedText(String(repeating: "x", count: 81)) == nil)
        // A ZWJ family emoji is one user-perceived character.
        let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦"
        #expect(WorkspaceAnnotation.normalizedText(String(repeating: family, count: 80)) != nil)
        #expect(WorkspaceAnnotation.normalizedText(String(repeating: family, count: 81)) == nil)
    }

    @Test
    func normalizedTextRejectsControlAndBidiCharacters() {
        #expect(WorkspaceAnnotation.normalizedText("") == nil)
        #expect(WorkspaceAnnotation.normalizedText("   ") == nil)
        #expect(WorkspaceAnnotation.normalizedText("line\nbreak") == nil)
        #expect(WorkspaceAnnotation.normalizedText("carriage\rreturn") == nil)
        #expect(WorkspaceAnnotation.normalizedText("bell\u{0007}") == nil)
        // Interior separators are rejected; edge ones fall to trimming.
        #expect(WorkspaceAnnotation.normalizedText("c1\u{0085}next") == nil)
        #expect(WorkspaceAnnotation.normalizedText("se\u{2028}p") == nil)
        #expect(WorkspaceAnnotation.normalizedText("ps\u{2029}ep") == nil)
        #expect(WorkspaceAnnotation.normalizedText("rtl\u{202E}override") == nil)
        #expect(WorkspaceAnnotation.normalizedText("iso\u{2066}late") == nil)
        // Emoji with ZWJ and variation selectors stay allowed.
        #expect(WorkspaceAnnotation.normalizedText("🏳️‍🌈 shipped 🚀") == "🏳️‍🌈 shipped 🚀")
    }

    @Test
    func validatedURLStringAcceptsOnlyAbsoluteHTTPAndHTTPS() {
        #expect(WorkspaceAnnotation.validatedURLString("https://github.com/pr/1") == "https://github.com/pr/1")
        #expect(WorkspaceAnnotation.validatedURLString(" http://internal.host/path ") == "http://internal.host/path")

        #expect(WorkspaceAnnotation.validatedURLString("") == nil)
        #expect(WorkspaceAnnotation.validatedURLString("ftp://example.com") == nil)
        #expect(WorkspaceAnnotation.validatedURLString("file:///etc/passwd") == nil)
        #expect(WorkspaceAnnotation.validatedURLString("javascript:alert(1)") == nil)
        #expect(WorkspaceAnnotation.validatedURLString("/relative/path") == nil)
        #expect(WorkspaceAnnotation.validatedURLString("example.com/no-scheme") == nil)
        #expect(WorkspaceAnnotation.validatedURLString("https://") == nil)
    }

    @Test
    func sanitizedAnnotationsDropsInvalidEntriesIndividually() {
        let sanitized = WorkspaceAnnotation.sanitizedAnnotations(
            [
                "pr": WorkspaceAnnotation(text: "PR #1", url: "https://example.com"),
                "Bad-Key": WorkspaceAnnotation(text: "kept? no", url: nil),
                "badurl": WorkspaceAnnotation(text: "x", url: "ftp://example.com"),
                "badtext": WorkspaceAnnotation(text: "a\nb", url: nil),
                "ok": WorkspaceAnnotation(text: "fine", url: nil),
            ],
            workspaceID: UUID()
        )

        #expect(sanitized.keys.sorted() == ["ok", "pr"])
        #expect(sanitized["pr"]?.url == "https://example.com")
    }
}

struct WorkspaceAnnotationReducerTests {
    private func makeState() -> (state: AppState, workspaceID: UUID) {
        let state = AppState.bootstrap()
        let workspaceID = state.workspacesByID.keys.first!
        return (state, workspaceID)
    }

    @Test
    func setAnnotationCanonicalizesKeyAndNormalizesText() {
        var (state, workspaceID) = makeState()

        let didApply = AppReducer.reduce(
            action: .setWorkspaceAnnotation(
                workspaceID: workspaceID,
                key: " PR ",
                annotation: WorkspaceAnnotation(text: "  PR #4512 ", url: "https://example.com/pr")
            ),
            state: &state
        )

        #expect(didApply)
        let annotation = state.workspacesByID[workspaceID]?.annotations["pr"]
        #expect(annotation?.text == "PR #4512")
        #expect(annotation?.url == "https://example.com/pr")
    }

    @Test
    func identicalSetAndMissingClearReturnFalse() {
        var (state, workspaceID) = makeState()
        let annotation = WorkspaceAnnotation(text: "PR #1", url: nil)
        #expect(AppReducer.reduce(
            action: .setWorkspaceAnnotation(workspaceID: workspaceID, key: "pr", annotation: annotation),
            state: &state
        ))

        #expect(AppReducer.reduce(
            action: .setWorkspaceAnnotation(workspaceID: workspaceID, key: "pr", annotation: annotation),
            state: &state
        ) == false)
        #expect(AppReducer.reduce(
            action: .clearWorkspaceAnnotation(workspaceID: workspaceID, key: "missing"),
            state: &state
        ) == false)

        #expect(AppReducer.reduce(
            action: .clearWorkspaceAnnotation(workspaceID: workspaceID, key: "PR"),
            state: &state
        ))
        #expect(state.workspacesByID[workspaceID]?.annotations.isEmpty == true)
    }

    @Test
    func invalidKeyTextAndURLAreRejected() {
        var (state, workspaceID) = makeState()

        #expect(AppReducer.reduce(
            action: .setWorkspaceAnnotation(
                workspaceID: workspaceID,
                key: "bad key",
                annotation: WorkspaceAnnotation(text: "x", url: nil)
            ),
            state: &state
        ) == false)
        #expect(AppReducer.reduce(
            action: .setWorkspaceAnnotation(
                workspaceID: workspaceID,
                key: "k",
                annotation: WorkspaceAnnotation(text: "a\u{202E}b", url: nil)
            ),
            state: &state
        ) == false)
        #expect(AppReducer.reduce(
            action: .setWorkspaceAnnotation(
                workspaceID: workspaceID,
                key: "k",
                annotation: WorkspaceAnnotation(text: "ok", url: "ftp://example.com")
            ),
            state: &state
        ) == false)
        #expect(AppReducer.reduce(
            action: .setWorkspaceAnnotation(
                workspaceID: UUID(),
                key: "k",
                annotation: WorkspaceAnnotation(text: "ok", url: nil)
            ),
            state: &state
        ) == false)
        #expect(state.workspacesByID[workspaceID]?.annotations.isEmpty == true)
    }

    @Test
    func countCapRejectsNewKeysButAllowsUpdatingExistingOnes() {
        var (state, workspaceID) = makeState()

        for index in 0..<WorkspaceAnnotation.maximumAnnotationsPerWorkspace {
            #expect(AppReducer.reduce(
                action: .setWorkspaceAnnotation(
                    workspaceID: workspaceID,
                    key: "key-\(index)",
                    annotation: WorkspaceAnnotation(text: "value \(index)", url: nil)
                ),
                state: &state
            ))
        }
        #expect(
            state.workspacesByID[workspaceID]?.annotations.count ==
                WorkspaceAnnotation.maximumAnnotationsPerWorkspace
        )

        #expect(AppReducer.reduce(
            action: .setWorkspaceAnnotation(
                workspaceID: workspaceID,
                key: "one-too-many",
                annotation: WorkspaceAnnotation(text: "nope", url: nil)
            ),
            state: &state
        ) == false)

        // Updating an existing key remains allowed at the limit.
        #expect(AppReducer.reduce(
            action: .setWorkspaceAnnotation(
                workspaceID: workspaceID,
                key: "key-0",
                annotation: WorkspaceAnnotation(text: "updated", url: nil)
            ),
            state: &state
        ))
        #expect(state.workspacesByID[workspaceID]?.annotations["key-0"]?.text == "updated")
    }
}

struct WorkspaceAnnotationPersistenceTests {
    @Test
    func workspaceStateLegacyDecodeDefaultsAnnotationsToEmpty() throws {
        var workspace = WorkspaceState.bootstrap(title: "Legacy")
        workspace.annotations = ["pr": WorkspaceAnnotation(text: "PR #1", url: nil)]
        var encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(workspace)
        ) as! [String: Any]
        encoded.removeValue(forKey: "annotations")
        let legacyData = try JSONSerialization.data(withJSONObject: encoded)

        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: legacyData)

        #expect(decoded.annotations.isEmpty)
        #expect(decoded.title == "Legacy")
    }

    @Test
    func workspaceLayoutSnapshotRoundTripsAnnotations() throws {
        var workspace = WorkspaceState.bootstrap(title: "Chips")
        workspace.annotations = [
            "pr": WorkspaceAnnotation(text: "PR #4512", url: "https://example.com/pr/4512"),
            "env": WorkspaceAnnotation(text: "staging", url: nil),
        ]
        var state = AppState.bootstrap()
        state.workspacesByID = [workspace.id: workspace]
        state.windows[0].workspaceIDs = [workspace.id]
        state.windows[0].selectedWorkspaceID = workspace.id

        let snapshot = WorkspaceLayoutSnapshot(state: state)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceLayoutSnapshot.self, from: data)
        let restored = decoded.makeAppState()

        #expect(restored.workspacesByID[workspace.id]?.annotations == workspace.annotations)
    }

    @Test
    func workspaceLayoutSnapshotDecodeDropsTamperedEntries() throws {
        var workspace = WorkspaceState.bootstrap(title: "Tampered")
        workspace.annotations = ["ok": WorkspaceAnnotation(text: "fine", url: nil)]
        let workspaceSnapshot = WorkspaceLayoutSnapshot(
            state: {
                var state = AppState.bootstrap()
                state.workspacesByID = [workspace.id: workspace]
                state.windows[0].workspaceIDs = [workspace.id]
                state.windows[0].selectedWorkspaceID = workspace.id
                return state
            }()
        ).workspacesByID[workspace.id]!

        // The layout profile file is user-editable: tamper the annotations
        // object directly the way a hand edit would.
        var workspaceObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(workspaceSnapshot)
        ) as! [String: Any]
        workspaceObject["annotations"] = [
            "ok": ["text": "fine"],
            "Bad Key": ["text": "dropped"],
            "badurl": ["text": "x", "url": "javascript:alert(1)"],
            "badtext": ["text": "a\u{202E}b"],
        ]
        let tamperedData = try JSONSerialization.data(withJSONObject: workspaceObject)

        let decoded = try JSONDecoder().decode(WorkspaceLayoutWorkspaceSnapshot.self, from: tamperedData)

        #expect(decoded.annotations.keys.sorted() == ["ok"])
    }
}
