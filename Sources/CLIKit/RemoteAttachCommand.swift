import CoreState
import Darwin
import Foundation
import RemoteProtocol

/// `toastty remote attach <remote-id> <conversation-id>`: attaches this
/// terminal to one session on a remote host from `remotes.toml`.
///
/// The Toastty app resolves the SSH destination and the host's attach command
/// over the local socket. This process then becomes `ssh`, which receives the
/// command as one argument. No shell on this Mac reads the host's text.
enum RemoteAttachCommand {
    struct Target: Equatable {
        var displayName: String
        var sshDestination: String
        var command: String
        var conversationTitle: String
    }

    static let queryID = "remote.attach-target"

    static func queryArguments(remoteID: String, conversationID: UUID) -> [String: AutomationJSONValue] {
        [
            "remoteID": .string(remoteID),
            "conversationID": .string(conversationID.uuidString),
        ]
    }

    static func target(from response: AutomationResponseEnvelope) throws -> Target {
        guard response.ok, let result = response.result else {
            throw ToasttyCLIError.runtime(response.error?.message ?? "could not resolve the remote session")
        }
        guard let sshDestination = result.string("sshDestination"),
              let command = result.string("command") else {
            throw ToasttyCLIError.runtime("the Toastty app returned an incomplete attach target")
        }
        return Target(
            displayName: result.string("displayName") ?? sshDestination,
            sshDestination: sshDestination,
            command: command,
            conversationTitle: result.string("conversationTitle") ?? "session"
        )
    }

    /// The `ssh` argument list. `--` ends option parsing, so neither the
    /// destination nor the command can be read as an `ssh` option. `-t` gives
    /// the multiplexer a terminal on the host.
    static func sshArguments(for target: Target) throws -> [String] {
        let destination = target.sshDestination
        let destinationIsPlain = destination.isEmpty == false
            && destination.hasPrefix("-") == false
            && destination.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && CharacterSet.whitespacesAndNewlines.contains(scalar) == false
                    && CharacterSet.controlCharacters.contains(scalar) == false
            }
        guard destinationIsPlain else {
            throw ToasttyCLIError.runtime("invalid SSH destination for this remote")
        }
        guard let command = RemoteTerminalAttachCommand.normalizedWireValue(target.command) else {
            throw ToasttyCLIError.runtime("the remote sent an attach command this Toastty cannot use")
        }
        return ["ssh", "-t", "--", destination, command]
    }

    static func run(
        socketPath: String,
        remoteID: String,
        conversationID: UUID,
        callerSessionID: String?,
        replaceProcess: ([String]) -> Int32 = RemoteAttachCommand.replaceProcess
    ) throws -> Int32 {
        let request = AutomationRequestEnvelope(
            requestID: UUID().uuidString,
            command: "app_control.run_query",
            callerSessionID: callerSessionID,
            payload: [
                "id": .string(queryID),
                "args": .object(queryArguments(remoteID: remoteID, conversationID: conversationID)),
            ]
        )
        let response = try ToasttySocketClient(socketPath: socketPath).send(request)
        let target = try target(from: response)
        let arguments = try sshArguments(for: target)
        fputs(statusLine(for: target) + "\n", stderr)
        return replaceProcess(arguments)
    }

    /// The line printed before `ssh` starts. The title comes from the host,
    /// so control characters are removed before it reaches the terminal.
    static func statusLine(for target: Target) -> String {
        func plain(_ value: String) -> String {
            String(String.UnicodeScalarView(value.unicodeScalars.filter { scalar in
                CharacterSet.controlCharacters.contains(scalar) == false
                    && CharacterSet.newlines.contains(scalar) == false
            }).prefix(120))
        }
        return "Attaching to \"\(plain(target.conversationTitle))\" on \(plain(target.displayName))"
            + " (ssh \(target.sshDestination))…"
    }

    /// Replaces this process with the named program. It returns only when
    /// the program cannot be started.
    static func replaceProcess(_ arguments: [String]) -> Int32 {
        guard let program = arguments.first else { return 1 }
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        execvp(program, &argv)
        let message = String(cString: strerror(errno))
        fputs("could not run \(program): \(message)\n", stderr)
        return 127
    }
}
