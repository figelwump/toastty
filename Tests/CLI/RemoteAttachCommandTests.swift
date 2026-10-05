import CoreState
import Foundation
import Testing
@testable import ToasttyCLIKit

struct RemoteAttachCommandTests {
    private static let conversationID = UUID(uuidString: "3F2A0C6E-8B1D-4E57-9A40-1C2D3E4F5A6B")!

    @Test
    func remoteAttachParsesTheRemoteAndConversation() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: ["remote", "attach", "mini", Self.conversationID.uuidString],
            environment: [:]
        )

        #expect(invocation.command == .remoteAttach(remoteID: "mini", conversationID: Self.conversationID))
    }

    @Test(arguments: [
        ["remote"],
        ["remote", "attach"],
        ["remote", "attach", "mini"],
        ["remote", "attach", "mini", "not-a-uuid"],
        ["remote", "detach", "mini", "3F2A0C6E-8B1D-4E57-9A40-1C2D3E4F5A6B"],
    ])
    func remoteAttachRejectsIncompleteArguments(arguments: [String]) {
        #expect(throws: ToasttyCLIError.self) {
            try ToasttyCLI.parse(arguments: arguments, environment: [:])
        }
    }

    /// The host's text reaches `ssh` as one argument after `--`, so no local
    /// shell reads it and `ssh` cannot take it, or the destination, for an
    /// option.
    @Test
    func sshReceivesTheHostCommandAsOneArgumentAfterTheOptionTerminator() throws {
        let hostCommand = #"env TOASTTY_PANEL_ID=X "$SHELL" -lc 'zmx attach x; $(touch /tmp/pwned) `id` && echo \'"#
        let arguments = try RemoteAttachCommand.sshArguments(for: .init(
            displayName: "Mini",
            sshDestination: "vishal@mini",
            command: hostCommand,
            conversationTitle: "Fix sidebar"
        ))

        #expect(arguments == ["ssh", "-t", "--", "vishal@mini", hostCommand])
    }

    @Test(arguments: ["-oProxyCommand=evil", "", "mini box", "mini\nbox"])
    func sshArgumentsRefuseADestinationThatIsNotAPlainHost(destination: String) {
        #expect(throws: ToasttyCLIError.self) {
            try RemoteAttachCommand.sshArguments(for: .init(
                displayName: "Mini",
                sshDestination: destination,
                command: "zmx attach x",
                conversationTitle: "Fix sidebar"
            ))
        }
    }

    @Test(arguments: ["", "one\ntwo", "bell\u{0007}"])
    func sshArgumentsRefuseAnUnusableHostCommand(command: String) {
        #expect(throws: ToasttyCLIError.self) {
            try RemoteAttachCommand.sshArguments(for: .init(
                displayName: "Mini",
                sshDestination: "mini",
                command: command,
                conversationTitle: "Fix sidebar"
            ))
        }
    }

    /// The title comes from the host and is printed before `ssh` starts.
    @Test
    func statusLineDropsControlCharactersFromHostText() {
        let line = RemoteAttachCommand.statusLine(for: .init(
            displayName: "Mini",
            sshDestination: "mini",
            command: "zmx attach x",
            conversationTitle: "Fix\u{001B}[2J sidebar\nhover\u{0007}"
        ))

        #expect(line == "Attaching to \"Fix[2J sidebarhover\" on Mini (ssh mini)…")
    }

    @Test
    func targetComesFromTheAppQueryResult() throws {
        let response = AutomationResponseEnvelope(
            requestID: "r",
            ok: true,
            result: [
                "remoteID": .string("mini"),
                "displayName": .string("Mini"),
                "sshDestination": .string("mini"),
                "command": .string("zmx attach x"),
                "conversationTitle": .string("Fix sidebar"),
            ],
            error: nil
        )

        #expect(try RemoteAttachCommand.target(from: response) == .init(
            displayName: "Mini",
            sshDestination: "mini",
            command: "zmx attach x",
            conversationTitle: "Fix sidebar"
        ))
    }

    /// The app's reason, such as "not connected", is what the user reads in
    /// the terminal.
    @Test
    func aRefusedQueryReportsTheAppsReason() {
        let response = AutomationResponseEnvelope(
            requestID: "r",
            ok: false,
            result: nil,
            error: AutomationResponseError(code: "INVALID_PAYLOAD", message: "Toastty is not connected to this remote now.")
        )

        #expect(throws: ToasttyCLIError.runtime("Toastty is not connected to this remote now.")) {
            try RemoteAttachCommand.target(from: response)
        }
    }
}
