import Foundation

/// What the check is asked: the app, how long it may take to answer, and
/// how long it must then stay up.
struct Options {
    static let usage = """
        usage: launch_check <Visor.app | Visor-<version>-macos.zip> [--startup <seconds>] [--hold <seconds>]
          --startup  how long the server may take to answer /api/hello (120)
          --hold     how long the app must then stay up and answering (60)
        """

    /// The app, or the .zip holding it, as an absolute path.
    var app: String
    var startup = 120
    var hold = 60

    /// The arguments after the program's name. A relative path is the
    /// caller's: `bazel run` starts the tool in its runfiles, and says
    /// where it was run from in BUILD_WORKING_DIRECTORY.
    init(_ arguments: [String]) throws {
        var app: String?
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "-h", "--help":
                throw LaunchCheckError.usage(Self.usage)
            case "--startup", "--hold":
                guard let value = rest.popFirst(), let seconds = Int(value), seconds > 0 else {
                    throw LaunchCheckError.usage("\(argument) takes a whole number of seconds\n\(Self.usage)")
                }
                if argument == "--startup" { startup = seconds } else { hold = seconds }
            default:
                guard !argument.hasPrefix("-") else { throw LaunchCheckError.usage("unknown option \(argument)\n\(Self.usage)") }
                guard app == nil else { throw LaunchCheckError.usage("one app at a time\n\(Self.usage)") }
                app = argument
            }
        }
        guard let app else { throw LaunchCheckError.usage(Self.usage) }
        let base = ProcessInfo.processInfo.environment["BUILD_WORKING_DIRECTORY"] ?? FileManager.default.currentDirectoryPath
        self.app = app.hasPrefix("/") ? app : URL(fileURLWithPath: base).appendingPathComponent(app).standardizedFileURL.path
    }
}
