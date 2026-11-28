// Sessions pinned to the top of the computer's list (`pin`, `unpin`;
// docs/protocol.md): a server that keeps pins says so at sign-in
// (`hello`'s `pins`, from 0.73). One before it says nothing, and is
// offered no Pin.

extension VisorAgentServer {
    public var pins: Bool { identity?.pins ?? false }
}
