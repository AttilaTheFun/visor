// Visor's executable given a command it doesn't have: its usage printed,
// and it ends, rather than open the app's window (NCH's check of #491:
// `Visor --help` opened the app, which then did its hand-over). Asked
// after the commands it has (MacServerAgent, MacAgentProxy, …), so what's
// left here is a word, or `--help`/`-h`. What macOS and the app itself pass
// to a launch (`-psn_…`, `-<default> <value>`, `--resume-sessions <ids>`)
// is left for the app.

import Foundation

enum MacCommandLine {
    /// The commands, as `Visor --help` lists them.
    static let usage = """
        usage: Visor                               the app (its window, menu and server)
               Visor --server                      the server agent (launchd's, as SMAppService registers it)
               Visor server-agent register         the server agent registered afresh from this app
               Visor admin-token                   the admin token, for a script
               Visor agent-proxy secret-set <name> agent-proxy's secret, read from standard input
               Visor agent-proxy secret-remove <name>
               Visor --help
        """

    /// Prints the usage and ends when the arguments are a command the
    /// app doesn't have, or a request for help; returns otherwise.
    static func handle(_ arguments: [String]) {
        guard let first = arguments.dropFirst().first else { return }
        if ["--help", "-h", "help"].contains(first) {
            print(usage)
            exit(0)
        }
        // A word: a command (macOS's and the app's own launch arguments
        // all begin with `-`).
        guard !first.hasPrefix("-") else { return }
        FileHandle.standardError.write(Data("Visor: no command \(first)\n\(usage)\n".utf8))
        exit(2)
    }
}
