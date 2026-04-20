import Foundation

public enum AppControlCommandKind: String, Codable, Equatable, Sendable {
    case action
    case query
}

public enum AppControlTargetSelector: String, Codable, Equatable, Sendable {
    case windowID
    case workspaceID
    case panelID
}

public enum AppControlParameterValueType: String, Codable, Equatable, Sendable {
    case string
    case integer
    case double
    case boolean
    case uuid
}

public struct AppControlParameterDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let summary: String
    public let valueType: AppControlParameterValueType
    public let required: Bool
    public let repeatable: Bool
    public let allowedValues: [String]?

    public init(
        name: String,
        summary: String,
        valueType: AppControlParameterValueType,
        required: Bool,
        repeatable: Bool = false,
        allowedValues: [String]? = nil
    ) {
        self.name = name
        self.summary = summary
        self.valueType = valueType
        self.required = required
        self.repeatable = repeatable
        self.allowedValues = allowedValues
    }
}

public struct AppControlCommandDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let kind: AppControlCommandKind
    public let summary: String
    public let selectors: [AppControlTargetSelector]
    public let parameters: [AppControlParameterDescriptor]
    public let aliases: [String]

    public init(
        id: String,
        kind: AppControlCommandKind,
        summary: String,
        selectors: [AppControlTargetSelector],
        parameters: [AppControlParameterDescriptor] = [],
        aliases: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.selectors = selectors
        self.parameters = parameters
        self.aliases = aliases
    }
}

public struct AppControlCatalogListing: Codable, Equatable, Sendable {
    public let commands: [AppControlCommandDescriptor]

    public init(commands: [AppControlCommandDescriptor]) {
        self.commands = commands
    }
}
