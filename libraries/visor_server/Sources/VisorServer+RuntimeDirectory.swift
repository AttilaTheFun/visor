// Where the server keeps its sockets: its SSH socket and each agent host's.
// By default they sit beside its data, in this user's home. A home that
// can't hold a socket (a folder shared into a container over virtiofs,
// as Shireworks' primary container's /root is: "Invalid argument") names
// another place with VISOR_RUNTIME_DIR, a folder on the computer's own disk
// that lasts as long as the computer does (a container's /run). Not
// XDG_RUNTIME_DIR: a desktop's is removed when the user's last session ends,
// and the hosts' sockets must outlive the server. A binary may place the
// hosts' sockets itself (`placedHostSocketFolder`: Visor.app's in the app
// group's container, 0.66 behind a setting), with short names.

import Foundation
import VisorAgent
import VisorSystem

extension VisorServer {
    /// VISOR_RUNTIME_DIR, when it is set: the sockets' folder.
    public nonisolated static func runtimeDirectory(in environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        HostFolders.runtimeDirectory(in: environment)
    }

    /// Where the binary keeps the agents' hosts' sockets (with short
    /// names, `h-<8 hex>.sock`), unless VISOR_RUNTIME_DIR names a place;
    /// nil, beside the hosts' log. Set before the server starts.
    @MainActor public static var placedHostSocketFolder: URL? {
        get { AgentChildren.placedSocketFolder }
        set { AgentChildren.placedSocketFolder = newValue }
    }
}
