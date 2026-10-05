import CoreState
import Foundation
import RemoteProtocol
import Testing

struct RemoteTerminalAttachCommandTests {
    private static let panelID = UUID(uuidString: "3F2A0C6E-8B1D-4E57-9A40-1C2D3E4F5A6B")!

    @Test func composeSetsThePaneVariablesAndRunsTheRecipeInALoginShell() throws {
        let command = try #require(RemoteTerminalAttachCommand.compose(
            recipe: "zmx attach toastty.$TOASTTY_PANEL_ID",
            panelID: Self.panelID,
            profileID: "zmx"
        ))

        #expect(command == "env TOASTTY_PANEL_ID=3F2A0C6E-8B1D-4E57-9A40-1C2D3E4F5A6B"
            + " TOASTTY_TERMINAL_PROFILE_ID=zmx"
            + #" "$SHELL" -lc 'zmx attach toastty.$TOASTTY_PANEL_ID'"#)
    }

    @Test(arguments: [
        "tmux attach -t 'x'",
        #"tmux attach -t x\y"#,
        "one\ntwo",
        "tab\u{0009}separated",
        "   ",
        String(repeating: "a", count: RemoteTerminalAttachCommand.maximumRecipeByteCount + 1),
    ])
    func composeRefusesARecipeThatShellsWouldReadDifferently(recipe: String) {
        #expect(RemoteTerminalAttachCommand.isValidRecipe(recipe) == false)
        #expect(RemoteTerminalAttachCommand.compose(recipe: recipe, panelID: Self.panelID, profileID: "zmx") == nil)
    }

    @Test(arguments: ["", "-x", "a b", "a;b", "a$b", "a'b"])
    func composeRefusesAProfileIDThatIsNotAPlainIdentifier(profileID: String) {
        #expect(RemoteTerminalAttachCommand.compose(
            recipe: "zmx attach x", panelID: Self.panelID, profileID: profileID
        ) == nil)
    }

    @Test func wireValueDropsEmptyMultiLineAndOversizedText() {
        #expect(RemoteTerminalAttachCommand.normalizedWireValue("zmx attach x") == "zmx attach x")
        #expect(RemoteTerminalAttachCommand.normalizedWireValue(nil) == nil)
        #expect(RemoteTerminalAttachCommand.normalizedWireValue("  ") == nil)
        #expect(RemoteTerminalAttachCommand.normalizedWireValue("a\nb") == nil)
        #expect(RemoteTerminalAttachCommand.normalizedWireValue("a\u{001B}[0m") == nil)
        #expect(RemoteTerminalAttachCommand.normalizedWireValue(
            String(repeating: "a", count: RemoteTerminalAttachCommand.maximumWireByteCount + 1)
        ) == nil)
    }

    /// The SSH server hands the command to the host user's login shell with
    /// `-c`. This runs the composed text that way in each installed shell and
    /// checks that the recipe sees the pane variables, that shell syntax in
    /// the recipe stays inside the recipe, and that nothing else runs.
    @Test(arguments: ["/bin/zsh", "/bin/bash", "/usr/local/bin/fish", "/opt/homebrew/bin/fish"])
    func composedCommandReadsTheSameInEachLoginShell(shellPath: String) throws {
        guard FileManager.default.isExecutableFile(atPath: shellPath) else { return }
        // The recipe prints its two variables and a literal with characters
        // that an unquoted context would expand or split.
        let command = try #require(RemoteTerminalAttachCommand.compose(
            recipe: #"printf "%s|%s|%s" "$TOASTTY_PANEL_ID" "$TOASTTY_TERMINAL_PROFILE_ID" "a;b && c * #d""#,
            panelID: Self.panelID,
            profileID: "zmx.profile-1"
        ))

        let output = try Self.run(shellPath: shellPath, command: command)

        #expect(output == "3F2A0C6E-8B1D-4E57-9A40-1C2D3E4F5A6B|zmx.profile-1|a;b && c * #d")
    }

    private static func run(shellPath: String, command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", command]
        // `$SHELL` names the login shell that the composed command starts.
        // A scratch HOME keeps the developer's shell startup files out.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-attach-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        process.environment = [
            "SHELL": shellPath,
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "XDG_CONFIG_HOME": home.appendingPathComponent("config").path,
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }
}

struct RemoteConversationSummaryTerminalAttachTests {
    private static func makeSummary(terminalAttachCommand: String?) -> RemoteConversationSummary {
        RemoteConversationSummary(
            conversationID: RemoteConversationID(),
            provider: .claude,
            title: "Attach",
            state: .working,
            inputAvailability: .unavailable(reason: .working),
            terminalAttachCommand: terminalAttachCommand,
            latestSequence: 0,
            updatedAt: Date(timeIntervalSince1970: 1_786_000_000)
        )
    }

    @Test func attachCommandRoundTripsAndIsAbsentWhenUnset() throws {
        let encoder = ConversationEventCoding.makeEncoder()
        let decoder = ConversationEventCoding.makeDecoder()

        let plain = try encoder.encode(Self.makeSummary(terminalAttachCommand: nil))
        let plainObject = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(plainObject["terminalAttachCommand"] == nil)
        #expect(try decoder.decode(RemoteConversationSummary.self, from: plain).terminalAttachCommand == nil)

        let command = "env TOASTTY_PANEL_ID=X \"$SHELL\" -lc 'zmx attach x'"
        let attached = try encoder.encode(Self.makeSummary(terminalAttachCommand: command))
        #expect(try decoder.decode(RemoteConversationSummary.self, from: attached).terminalAttachCommand == command)
    }

    /// A value this client cannot use removes the attach affordance and keeps
    /// the rest of the row.
    @Test func unusableAttachCommandDecodesAsAbsent() throws {
        let encoder = ConversationEventCoding.makeEncoder()
        let decoder = ConversationEventCoding.makeDecoder()
        let data = try encoder.encode(Self.makeSummary(terminalAttachCommand: "zmx attach x"))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        for unusable: Any in ["line one\nline two", 42, ["nested": true]] {
            object["terminalAttachCommand"] = unusable
            let decoded = try decoder.decode(
                RemoteConversationSummary.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            #expect(decoded.terminalAttachCommand == nil)
            #expect(decoded.title == "Attach")
        }
    }
}
