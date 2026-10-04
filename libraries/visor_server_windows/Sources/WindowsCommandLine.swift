/// How Windows hands a program its arguments and environment: one command
/// line the program splits again (the C runtime's rules), and a block of
/// NAME=value strings.
enum WindowsCommandLine {
    /// The arguments as one command line, each quoted where it needs to be
    /// so the program reads it back as it was.
    static func join(_ arguments: [String]) -> String {
        arguments.map(quoted).joined(separator: " ")
    }

    static func quoted(_ argument: String) -> String {
        guard argument.isEmpty || argument.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) else { return argument }
        var out = "\""
        var backslashes = 0
        for character in argument {
            if character == "\\" {
                backslashes += 1
            } else if character == "\"" {
                // Backslashes before a quote are doubled, and the quote escaped.
                out += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
                backslashes = 0
            } else {
                out += String(repeating: "\\", count: backslashes) + String(character)
                backslashes = 0
            }
        }
        // Backslashes before the closing quote are doubled.
        return out + String(repeating: "\\", count: backslashes * 2) + "\""
    }

    /// The environment as CreateProcessW takes it (with
    /// CREATE_UNICODE_ENVIRONMENT): sorted, each NAME=value ended by a nul,
    /// the whole ended by another.
    static func environmentBlock(_ environment: [String: String]) -> [UInt16] {
        let entries = environment.sorted { $0.key.uppercased() < $1.key.uppercased() }
        var block: [UInt16] = []
        for (name, value) in entries {
            block += Array("\(name)=\(value)".utf16)
            block.append(0)
        }
        block.append(0)
        return block
    }
}
