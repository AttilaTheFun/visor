/// How the server is run: what `run` and `start` take after the command.
struct ServerOptions: Sendable {
    var port: UInt16?
    /// The file it logs to; the terminal when nil.
    var log: String?
    /// A process to wait for before listening: the server this one
    /// replaces.
    var after: Int32?
    /// The sessions to carry on (`--resume-sessions`, read by the server).
    var resume: String?

    /// None given.
    init() {}

    /// Reads them; what it does not know is returned as the problem.
    init(_ arguments: [String]) throws(CommandLineError) {
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            guard let value = rest.popFirst() else { throw .usage("\(flag) needs a value") }
            switch flag {
            case "--port":
                guard let port = UInt16(value) else { throw .usage("--port takes a number") }
                self.port = port
            case "--log": log = value
            case "--after":
                guard let pid = Int32(value) else { throw .usage("--after takes a process id") }
                after = pid
            case "--resume-sessions": resume = value
            default: throw .usage("unknown option \(flag)")
            }
        }
    }

    /// As arguments again, for a run started from this one.
    var arguments: [String] {
        var out: [String] = []
        if let port { out += ["--port", String(port)] }
        if let log { out += ["--log", log] }
        if let after { out += ["--after", String(after)] }
        if let resume { out += ["--resume-sessions", resume] }
        return out
    }
}
