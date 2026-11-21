import Foundation

/// A tool's arguments, checked against its params: every one known, every
/// required one there, each of its kind (an integer may come as a string of
/// digits, a boolean as "true" or "false").
public struct Arguments: Sendable {
    let values: [String: JSON]

    public static func parse(_ json: JSON, _ params: [Param], tool: String) throws -> Arguments {
        let given: [String: JSON]
        switch json {
        case .null: given = [:]
        case .object(let object): given = object
        default: throw ToolError.invalid("\(tool)'s arguments are an object")
        }
        let names = params.map(\.name)
        for key in given.keys.sorted() where !names.contains(key) {
            throw ToolError.invalid("\(tool) takes no argument \(key) (it takes \(names.joined(separator: ", ")))")
        }
        var values: [String: JSON] = [:]
        for param in params {
            guard let value = given[param.name], value != .null else {
                if param.required { throw ToolError.invalid("\(tool) needs \(param.name)") }
                continue
            }
            switch param.kind {
            case .string:
                guard let string = value.stringValue else { throw ToolError.invalid("\(param.name) is a string") }
                if string.isEmpty && !param.allowsEmpty { throw ToolError.invalid("\(param.name) is empty") }
                if let choices = param.choices, !choices.contains(string) {
                    throw ToolError.invalid("\(param.name) is one of \(choices.joined(separator: ", ")): \(string)")
                }
                values[param.name] = .string(string)
            case .integer:
                let int: Int?
                if let number = value.intValue {
                    int = number
                } else if let text = value.stringValue, !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) {
                    int = Int(text)
                } else {
                    int = nil
                }
                guard let int else { throw ToolError.invalid("\(param.name) is an integer") }
                if let range = param.range, !range.contains(int) {
                    throw ToolError.invalid("\(param.name) is between \(range.lowerBound) and \(range.upperBound): \(int)")
                }
                values[param.name] = .int(int)
            case .boolean:
                if let bool = value.boolValue {
                    values[param.name] = .bool(bool)
                } else if let text = value.stringValue, text == "true" || text == "false" {
                    values[param.name] = .bool(text == "true")
                } else {
                    throw ToolError.invalid("\(param.name) is true or false")
                }
            }
        }
        return Arguments(values: values)
    }

    public func string(_ name: String) -> String? { values[name]?.stringValue }
    public func int(_ name: String) -> Int? { values[name]?.intValue }
    public func bool(_ name: String) -> Bool? { values[name]?.boolValue }
}
