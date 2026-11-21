import Foundation

/// One argument a tool takes: its JSON Schema and its check are the same
/// declaration.
public struct Param: Sendable {
    public let name: String
    public let kind: ParamKind
    public let required: Bool
    public let description: String
    public var choices: [String]?
    public var range: ClosedRange<Int>?
    /// A string that may be "" (a body); others may not.
    public var allowsEmpty = false

    public init(_ name: String, _ kind: ParamKind, required: Bool = false, _ description: String,
                choices: [String]? = nil, range: ClosedRange<Int>? = nil, allowsEmpty: Bool = false) {
        self.name = name
        self.kind = kind
        self.required = required
        self.description = description
        self.choices = choices
        self.range = range
        self.allowsEmpty = allowsEmpty
    }

    var schema: JSON {
        var fields: [String: JSON] = ["description": .string(description)]
        switch kind {
        case .string: fields["type"] = "string"
        case .integer: fields["type"] = "integer"
        case .boolean: fields["type"] = "boolean"
        }
        if let choices { fields["enum"] = .array(choices.map(JSON.string)) }
        if let range {
            fields["minimum"] = .int(range.lowerBound)
            fields["maximum"] = .int(range.upperBound)
        }
        return .object(fields)
    }

    static let repo = Param("repo", .string, required: true, "The repository, owner/name (e.g. AttilaTheFun/oss).")
    static let number = Param("number", .integer, required: true, "The pull request's number.", range: 1...Int(Int32.max))
    static let runID = Param("run_id", .integer, required: true, "The workflow run's id (runs lists them).", range: 1...Int.max)
}
