import Foundation

/// Validated OSC 7501 data copied from the terminal runtime.
public struct TerminalProgramStatusReport: Equatable, Sendable {
    public enum State: String, Sendable { case idle, working, done, blocked, error, clear }
    public enum Kind: String, Sendable { case permission, question, auth }

    public var state: State
    public var id: String?
    public var app: String?
    public var title: String?
    public var message: String?
    public var kind: Kind?
    public var progress: Int?

    public init(state: State, id: String? = nil, app: String? = nil, title: String? = nil,
                message: String? = nil, kind: Kind? = nil, progress: Int? = nil) {
        self.state = state
        self.id = id
        self.app = app
        self.title = title
        self.message = message
        self.kind = kind
        self.progress = progress
    }
}

public enum TerminalProgramStatusEvent: Equatable, Sendable {
    case report(TerminalProgramStatusReport)
    case prompt
    case reset
    case exit
}

public struct TerminalProgramStatusPresentation: Equatable, Sendable {
    public let record: TerminalProgramStatusReport
    public let app: String?
    public let rootTitle: String?
}

/// Each terminal has one bounded record set. Updates replace complete records.
public struct TerminalProgramStatusRecords: Equatable, Sendable {
    public private(set) var records: [String: TerminalProgramStatusReport] = [:]
    private var updateOrder: [String] = []

    public init() {}

    public mutating func apply(_ event: TerminalProgramStatusEvent) {
        switch event {
        case .report(let report):
            let key = report.id ?? ""
            if report.state == .clear {
                remove { key.isEmpty || $0 == key || $0.hasPrefix(key + "/") }
                return
            }
            updateOrder.removeAll { $0 == key }
            updateOrder.append(key)
            records[key] = report
            if updateOrder.count > 256 {
                records.removeValue(forKey: updateOrder.removeFirst())
            }
        case .prompt, .exit:
            let snapshot = records
            remove { snapshot[$0]?.state != .done && snapshot[$0]?.state != .error }
        case .reset:
            records.removeAll()
            updateOrder.removeAll()
        }
    }

    public mutating func acknowledgeResults() {
        let snapshot = records
        remove { snapshot[$0]?.state == .done || snapshot[$0]?.state == .error }
    }

    public var presentation: TerminalProgramStatusPresentation? {
        var selected: String?
        for key in updateOrder {
            guard let candidate = records[key] else { continue }
            if let previousKey = selected, let previous = records[previousKey] {
                if priority(candidate.state) < priority(previous.state) { continue }
                if priority(candidate.state) == priority(previous.state), previousKey.isEmpty { continue }
            }
            selected = key
        }
        guard let key = selected, let record = records[key] else { return nil }
        var ancestor = key
        var app = record.app
        while app == nil, !ancestor.isEmpty {
            ancestor = ancestor.lastIndex(of: "/").map { String(ancestor[..<$0]) } ?? ""
            app = records[ancestor]?.app
        }
        return .init(record: record, app: app, rootTitle: records[""]?.title)
    }

    private mutating func remove(where predicate: (String) -> Bool) {
        let removed = Set(updateOrder.filter(predicate))
        for key in removed { records.removeValue(forKey: key) }
        updateOrder.removeAll { removed.contains($0) }
    }

    private func priority(_ state: TerminalProgramStatusReport.State) -> Int {
        switch state {
        case .blocked: 5
        case .error: 4
        case .working: 3
        case .done: 2
        case .idle: 1
        case .clear: 0
        }
    }
}
