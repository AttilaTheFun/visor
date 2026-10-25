import VisorProtocol

extension AgentServerConnection {
    /// What the computer is using and for whom, asked now; nil when it does
    /// not answer or does not say.
    public func resources() async -> ServerResources? {
        try? await server.resources()
    }
}
