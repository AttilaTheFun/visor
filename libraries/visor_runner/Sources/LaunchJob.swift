import Foundation

/// A launchd job of the Runner's (launchd.plist(5)): its program started at
/// login and kept running, in the user's session, its output in a log.
public struct LaunchJob: Codable, Equatable, Sendable {
    public var label: String
    public var programArguments: [String]
    public var environmentVariables: [String: String]
    public var runAtLoad = true
    public var keepAlive = true
    public var standardOutPath: String
    public var standardErrorPath: String

    public init(label: String, programArguments: [String], environmentVariables: [String: String] = [:], log: String) {
        self.label = label
        self.programArguments = programArguments
        self.environmentVariables = environmentVariables
        standardOutPath = log
        standardErrorPath = log
    }

    enum CodingKeys: String, CodingKey {
        case label = "Label", programArguments = "ProgramArguments", environmentVariables = "EnvironmentVariables"
        case runAtLoad = "RunAtLoad", keepAlive = "KeepAlive", standardOutPath = "StandardOutPath", standardErrorPath = "StandardErrorPath"
    }

    /// Its plist, as launchd reads it.
    public func plist() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try encoder.encode(self)
    }

    /// The job a plist file holds, if it is one of these.
    public static func read(_ file: URL) -> LaunchJob? {
        (try? Data(contentsOf: file)).flatMap { try? PropertyListDecoder().decode(LaunchJob.self, from: $0) }
    }
}
