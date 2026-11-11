// Repositories a moved session works in, where the server keeps them apart
// (VISOR_SOURCES_DIR): each a fresh clone of its remote, never a copy of a
// working tree (Logan, 11 Nov), so only one whose remote has everything it
// has can come.

import Foundation
import VisorProtocol

extension VisorServer {
    /// Why `project` can't be cloned as it is: nil when it can.
    static func notClonable(_ project: MigrationProject) -> String? {
        guard project.remote != nil else { return "has no remote to clone it from" }
        return project.unshared ? "has changes, files or commits its remote doesn't" : nil
    }

    /// GitHub's SSH remote as HTTPS (`git@github.com:owner/name.git`,
    /// `ssh://git@github.com/owner/name.git`); any other as it is.
    static func overHTTPS(_ remote: String) -> String {
        for prefix in ["git@github.com:", "ssh://git@github.com/"] where remote.hasPrefix(prefix) {
            return "https://github.com/" + remote.dropFirst(prefix.count)
        }
        return remote
    }
}
