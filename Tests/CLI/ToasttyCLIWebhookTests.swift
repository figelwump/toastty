import CoreState
import Foundation
import Testing
@testable import ToasttyCLIKit

struct ToasttyCLIWebhookTests {
    @Test
    func webhookAddMapsFlagsAndResolvesRoots() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "webhook", "add", "grok", "https://hooks.example.com/w",
                "--events", "needs_you,merged", "--root", "repo", "--root", "/abs",
                "--external-ref-prefix", "grok:", "--auth", "header:X-Sender-Key",
                "--wait", "--timeout", "30",
            ],
            environment: ["PWD": "/work"]
        )
        #expect(invocation.command == .appControlRun(kind: .action, id: "webhook.add", args: [
            "name": .string("grok"),
            "url": .string("https://hooks.example.com/w"),
            "events": .array([.string("needs_you,merged")]),
            "roots": .array([.string("/work/repo"), .string("/abs")]),
            "externalRefPrefix": .string("grok:"),
            "auth": .string("header:X-Sender-Key"),
        ]))
        #expect(invocation.webhook == CLIWebhookOutput(kind: .saved, name: "grok", waitTimeout: 30))
    }

    @Test
    func webhookCommandsMapToTheirSocketCommands() throws {
        let list = try ToasttyCLI.parse(arguments: ["webhook", "list"], environment: [:])
        #expect(list.command == .appControlRun(kind: .query, id: "webhook.list", args: [:]))
        let test = try ToasttyCLI.parse(arguments: ["webhook", "test", "grok"], environment: [:])
        #expect(test.command == .appControlRun(kind: .action, id: "webhook.test", args: ["name": .string("grok")]))
        let remove = try ToasttyCLI.parse(arguments: ["webhook", "remove", "grok"], environment: [:])
        #expect(remove.command == .appControlRun(kind: .action, id: "webhook.remove", args: ["name": .string("grok")]))
        let set = try ToasttyCLI.parse(arguments: ["webhook", "set", "grok", "--events", "needs_you", "--external-ref-prefix", ""], environment: [:])
        #expect(set.command == .appControlRun(kind: .action, id: "webhook.set", args: [
            "name": .string("grok"), "events": .array([.string("needs_you")]), "externalRefPrefix": .string(""),
        ]))
    }

    @Test
    func webhookUsageErrors() {
        for arguments in [
            ["webhook"],
            ["webhook", "add", "grok"],
            ["webhook", "add", "grok", "https://a.example", "--timeout", "5"],
            ["webhook", "add", "grok", "https://a.example", "--url", "https://b.example"],
            ["webhook", "set", "grok"],
            ["webhook", "rotate-secret", "grok"],
            ["webhook", "approve", "grok"],
        ] {
            #expect(throws: ToasttyCLIError.self, "\(arguments)") {
                _ = try ToasttyCLI.parse(arguments: arguments, environment: [:])
            }
        }
    }
}
