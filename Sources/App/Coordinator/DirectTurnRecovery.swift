import Foundation

/// What a quit or a crash left of a direct session's turn: the messages
/// that the session's process got and whose turn had not ended
/// (`CoordinatorWorkspaceRecord.DirectSession.messagesInTurn`), read
/// against Claude's transcript file.
///
/// The file is what the resumed conversation knows. A message whose record
/// is in it was taken: its turn was cut off, and the reply may be missing
/// or partial. A message whose record is not in it never reached the
/// conversation, whatever the process read before it ended.
enum DirectTurnRecovery {
    typealias Message = CoordinatorWorkspaceRecord.UnfinishedMessage

    struct Outcome: Equatable {
        /// In the transcript: their turn was cut off. In the order sent.
        var taken: [Message] = []
        /// Not in the transcript: the conversation does not have them.
        var notTaken: [Message] = []
        /// The transcript could not be read, so nobody knows.
        var unknown: [Message] = []
    }

    static func resolve(_ messages: [Message], transcriptPath: String) -> Outcome {
        guard messages.isEmpty == false else { return Outcome() }
        guard let data = FileManager.default.contents(atPath: transcriptPath) else {
            return Outcome(unknown: messages)
        }
        let taken = takenMessageIDs(in: data, among: Set(messages.map(\.messageID)))
        var outcome = Outcome()
        for message in messages {
            if taken.contains(message.messageID) {
                outcome.taken.append(message)
            } else {
                outcome.notTaken.append(message)
            }
        }
        return outcome
    }

    /// The IDs among `ids` that a user record of the transcript has as its
    /// `uuid`. Claude writes one JSON object per line. A line that a kill
    /// cut short does not parse and counts as no record.
    static func takenMessageIDs(in transcript: Data, among ids: Set<String>) -> Set<String> {
        guard ids.isEmpty == false else { return [] }
        let needles = ids.map { Data($0.utf8) }
        var found: Set<String> = []
        for slice in transcript.split(separator: UInt8(ascii: "\n")) {
            let line = Data(slice)
            // A long conversation has many lines: only one that names an ID
            // is parsed.
            guard needles.contains(where: { line.range(of: $0) != nil }),
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "user",
                  let uuid = object["uuid"] as? String,
                  ids.contains(uuid) else { continue }
            found.insert(uuid)
        }
        return found
    }
}
