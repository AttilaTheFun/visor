// What the server says it is doing, a line at a time, to wherever the
// platform keeps such lines: the system log on a Mac, the terminal or a
// log file for the command-line server.

extension VisorServer {
    nonisolated static func log(_ line: String) {
        ServerPlatform.current.log(line)
    }
}
