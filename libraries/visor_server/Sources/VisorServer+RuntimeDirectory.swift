// Where the server keeps its sockets: its SSH socket and each agent host's.
// By default they sit beside its data, in this user's home. A home that
// can't hold a socket (a folder shared into a container over virtiofs,
// as Shireworks' primary container's /root is: "Invalid argument") names
// another place with VISOR_RUNTIME_DIR, a folder on the computer's own disk
// that lasts as long as the computer does (a container's /run). Not
// XDG_RUNTIME_DIR: a desktop's is removed when the user's last session ends,
// and the hosts' sockets must outlive the server.

import Foundation

extension VisorServer {
    /// VISOR_RUNTIME_DIR, when it is set: the sockets' folder.
    public nonisolated static func runtimeDirectory(in environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        HostFolders.runtimeDirectory(in: environment)
    }
}
