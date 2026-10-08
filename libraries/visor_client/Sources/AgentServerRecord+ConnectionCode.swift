import VisorProtocol

public extension AgentServerRecord {
    /// A computer as its connection code gives it: the name, the address,
    /// the password, its id and its other paths (an SSH code's host is its
    /// SSH path; the others are how a device without SSH, or not yet let
    /// in over it, comes in). The sign-in the code names, or none
    /// (`authentication` empty: a held computer keeps its own, a new one
    /// signs in by password).
    init(code: ConnectionCode) {
        self.init(name: code.name, address: code.host, secret: code.password, serverID: code.id, paths: code.paths,
                  authentication: code.auth)
    }
}
