import Foundation

/// A GraphQL document as GitHubGate reads it (docs/github-gate-rules.md,
/// §3.2): its operations, and for each its root selections with their
/// arguments. What lies below a root field is parsed and set aside: only the
/// root names what a mutation does. A document that isn't GraphQL is none.
struct GraphQLDocument: Equatable, Sendable {
    var operations: [Operation]

    struct Operation: Equatable, Sendable {
        /// `query`, `mutation` or `subscription`.
        var kind: String
        var name: String?
        var root: [Selection]
    }

    /// A root selection: a field (its name, not its alias), or a fragment,
    /// which a mutation's root may not have here.
    enum Selection: Equatable, Sendable {
        case field(name: String, arguments: [String: Value], directives: Bool)
        case fragment
    }

    indirect enum Value: Equatable, Sendable {
        case variable(String)
        case int(String)
        case float(String)
        case string(String)
        case bool(Bool)
        case null
        case enumeration(String)
        case list([Value])
        case object([String: Value])

        /// As JSON, its variables given: nil when one isn't.
        func resolved(_ variables: [String: GateJSON]) -> GateJSON? {
            switch self {
            case .variable(let name): return variables[name] ?? .null
            case .int(let digits), .float(let digits): return .number(digits)
            case .string(let text), .enumeration(let text): return .string(text)
            case .bool(let value): return .bool(value)
            case .null: return .null
            case .list(let items):
                var resolved: [GateJSON] = []
                for item in items {
                    guard let value = item.resolved(variables) else { return nil }
                    resolved.append(value)
                }
                return .array(resolved)
            case .object(let fields):
                var resolved: [String: GateJSON] = [:]
                for (key, field) in fields {
                    guard let value = field.resolved(variables) else { return nil }
                    resolved[key] = value
                }
                return .object(resolved)
            }
        }
    }

    static func parse(_ text: String) -> GraphQLDocument? {
        guard let tokens = Lexer.tokens(text) else { return nil }
        var parser = Parser(tokens: tokens)
        return parser.document()
    }

    // MARK: Tokens

    enum Token: Equatable, Sendable {
        case punctuator(String)
        case name(String)
        case int(String)
        case float(String)
        case string(String)
    }

    enum Lexer {
        static func tokens(_ text: String) -> [Token]? {
            let characters = Array(text.unicodeScalars)
            var tokens: [Token] = []
            var at = 0
            func isNameStart(_ c: Unicode.Scalar) -> Bool { c == "_" || ("a"..."z").contains(c) || ("A"..."Z").contains(c) }
            func isNameContinue(_ c: Unicode.Scalar) -> Bool { isNameStart(c) || ("0"..."9").contains(c) }
            while at < characters.count {
                let c = characters[at]
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "," || c == "\u{FEFF}" {
                    at += 1
                } else if c == "#" {
                    while at < characters.count, characters[at] != "\n", characters[at] != "\r" { at += 1 }
                } else if "!$&()=:@[]{}|".unicodeScalars.contains(c) {
                    tokens.append(.punctuator(String(c)))
                    at += 1
                } else if c == ".", at + 2 < characters.count, characters[at + 1] == ".", characters[at + 2] == "." {
                    tokens.append(.punctuator("..."))
                    at += 3
                } else if isNameStart(c) {
                    let start = at
                    while at < characters.count, isNameContinue(characters[at]) { at += 1 }
                    tokens.append(.name(String(String.UnicodeScalarView(characters[start..<at]))))
                } else if c == "-" || ("0"..."9").contains(c) {
                    let start = at
                    var float = false
                    at += 1
                    while at < characters.count {
                        let d = characters[at]
                        if ("0"..."9").contains(d) {
                            at += 1
                        } else if d == "." || d == "e" || d == "E" || ((d == "+" || d == "-") && (characters[at - 1] == "e" || characters[at - 1] == "E")) {
                            float = true
                            at += 1
                        } else {
                            break
                        }
                    }
                    let digits = String(String.UnicodeScalarView(characters[start..<at]))
                    guard Double(digits) != nil else { return nil }
                    tokens.append(float ? .float(digits) : .int(digits))
                } else if c == "\"" {
                    if at + 2 < characters.count, characters[at + 1] == "\"", characters[at + 2] == "\"" {
                        // A block string: everything to the next """ (\""" escapes one).
                        at += 3
                        var value = String.UnicodeScalarView()
                        var closed = false
                        while at < characters.count {
                            if characters[at] == "\"", at + 2 < characters.count, characters[at + 1] == "\"", characters[at + 2] == "\"" {
                                at += 3
                                closed = true
                                break
                            }
                            if characters[at] == "\\", at + 3 < characters.count, characters[at + 1] == "\"",
                               characters[at + 2] == "\"", characters[at + 3] == "\"" {
                                value.append(contentsOf: "\"\"\"".unicodeScalars)
                                at += 4
                                continue
                            }
                            value.append(characters[at])
                            at += 1
                        }
                        guard closed else { return nil }
                        tokens.append(.string(String(value)))
                    } else {
                        at += 1
                        var value = String.UnicodeScalarView()
                        var closed = false
                        while at < characters.count {
                            let s = characters[at]
                            at += 1
                            if s == "\"" { closed = true; break }
                            if s == "\n" || s == "\r" { return nil }
                            if s == "\\" {
                                guard at < characters.count else { return nil }
                                let e = characters[at]
                                at += 1
                                switch e {
                                case "\"": value.append("\"")
                                case "\\": value.append("\\")
                                case "/": value.append("/")
                                case "b": value.append("\u{08}")
                                case "f": value.append("\u{0C}")
                                case "n": value.append("\n")
                                case "r": value.append("\r")
                                case "t": value.append("\t")
                                case "u":
                                    guard at + 4 <= characters.count,
                                          let code = UInt32(String(String.UnicodeScalarView(characters[at..<at + 4])), radix: 16),
                                          let scalar = Unicode.Scalar(code) else { return nil }
                                    value.append(scalar)
                                    at += 4
                                default: return nil
                                }
                            } else {
                                value.append(s)
                            }
                        }
                        guard closed else { return nil }
                        tokens.append(.string(String(value)))
                    }
                } else {
                    return nil
                }
            }
            return tokens
        }
    }

    // MARK: Parsing

    struct Parser {
        let tokens: [Token]
        var at = 0
        var depth = 0

        var next: Token? { at < tokens.count ? tokens[at] : nil }

        mutating func take(_ punctuator: String) -> Bool {
            guard next == .punctuator(punctuator) else { return false }
            at += 1
            return true
        }

        mutating func name() -> String? {
            guard case .name(let name)? = next else { return nil }
            at += 1
            return name
        }

        mutating func document() -> GraphQLDocument? {
            var operations: [Operation] = []
            while next != nil {
                if next == .punctuator("{") {
                    guard let root = selectionSet() else { return nil }
                    operations.append(Operation(kind: "query", name: nil, root: root))
                    continue
                }
                guard let keyword = name() else { return nil }
                switch keyword {
                case "query", "mutation", "subscription":
                    var operationName: String?
                    if case .name(let named)? = next {
                        operationName = named
                        at += 1
                    }
                    if next == .punctuator("("), !variableDefinitions() { return nil }
                    guard directives(), let root = selectionSet() else { return nil }
                    operations.append(Operation(kind: keyword, name: operationName, root: root))
                case "fragment":
                    guard name() != nil, name() == "on", name() != nil, directives(), selectionSet() != nil else { return nil }
                default:
                    return nil
                }
            }
            return operations.isEmpty ? nil : GraphQLDocument(operations: operations)
        }

        mutating func variableDefinitions() -> Bool {
            guard take("(") else { return false }
            while !take(")") {
                guard take("$"), name() != nil, take(":"), type() else { return false }
                if take("="), value(constant: true) == nil { return false }
                guard directives() else { return false }
            }
            return true
        }

        mutating func type() -> Bool {
            if take("[") {
                guard type(), take("]") else { return false }
            } else {
                guard name() != nil else { return false }
            }
            _ = take("!")
            return true
        }

        mutating func directives() -> Bool {
            while take("@") {
                guard name() != nil else { return false }
                if next == .punctuator("("), arguments() == nil { return false }
            }
            return true
        }

        mutating func arguments() -> [String: Value]? {
            guard take("(") else { return nil }
            var arguments: [String: Value] = [:]
            while !take(")") {
                guard let key = name(), take(":"), let value = value(constant: false), arguments[key] == nil else { return nil }
                arguments[key] = value
            }
            return arguments
        }

        mutating func value(constant: Bool) -> Value? {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64, let token = next else { return nil }
            at += 1
            switch token {
            case .punctuator("$"):
                guard !constant, let variable = name() else { return nil }
                return .variable(variable)
            case .int(let digits): return .int(digits)
            case .float(let digits): return .float(digits)
            case .string(let text): return .string(text)
            case .name("true"): return .bool(true)
            case .name("false"): return .bool(false)
            case .name("null"): return .null
            case .name(let word): return .enumeration(word)
            case .punctuator("["):
                var items: [Value] = []
                while !take("]") {
                    guard let item = value(constant: constant) else { return nil }
                    items.append(item)
                }
                return .list(items)
            case .punctuator("{"):
                var fields: [String: Value] = [:]
                while !take("}") {
                    guard let key = name(), take(":"), let field = value(constant: constant), fields[key] == nil else { return nil }
                    fields[key] = field
                }
                return .object(fields)
            default:
                return nil
            }
        }

        /// A selection set: its selections at this level (those below are
        /// parsed and set aside).
        mutating func selectionSet() -> [Selection]? {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64, take("{") else { return nil }
            var selections: [Selection] = []
            while !take("}") {
                if take("...") {
                    if next == .name("on") {
                        at += 1
                        guard name() != nil else { return nil }
                    } else if case .name = next {
                        at += 1
                        guard directives() else { return nil }
                        selections.append(.fragment)
                        continue
                    }
                    guard directives(), selectionSet() != nil else { return nil }
                    selections.append(.fragment)
                    continue
                }
                guard var field = name() else { return nil }
                if take(":") {
                    guard let named = name() else { return nil }
                    field = named
                }
                var arguments: [String: Value] = [:]
                if next == .punctuator("(") {
                    guard let given = self.arguments() else { return nil }
                    arguments = given
                }
                let before = at
                guard directives() else { return nil }
                let hasDirectives = at != before
                if next == .punctuator("{"), selectionSet() == nil { return nil }
                selections.append(.field(name: field, arguments: arguments, directives: hasDirectives))
            }
            return selections
        }
    }
}
