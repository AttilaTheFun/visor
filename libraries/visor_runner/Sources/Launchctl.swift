import Foundation
import VisorContainerHost

/// launchctl(1), for the jobs of this user's session (`gui/<uid>`): what
/// is loaded, loading a job's plist, and unloading it.
public struct Launchctl: Sendable {
    public var tool: Tool
    public var domain: String

    public init(program: String = "/bin/launchctl", domain: String = "gui/\(getuid())") {
        tool = Tool(program)
        self.domain = domain
    }

    public func loaded(_ label: String) -> Bool {
        tool.run(["print", "\(domain)/\(label)"])?.status == 0
    }

    /// The job in `plist` loaded, and so started (RunAtLoad); tried again
    /// for a few seconds while one of its label is still going away. Nil,
    /// or what launchctl said.
    public func load(_ plist: URL) -> String? {
        var said = "launchctl couldn't be run"
        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            guard let ran = tool.run(["bootstrap", domain, plist.path]) else { return said }
            if ran.status == 0 { return nil }
            said = ran.said
        }
        return said
    }

    /// The job unloaded, its program ended (SIGTERM). Nil, or what
    /// launchctl said.
    public func unload(_ label: String) -> String? {
        let ran = tool.run(["bootout", "\(domain)/\(label)"])
        return loaded(label) ? (ran?.said ?? "launchctl couldn't be run") : nil
    }
}
