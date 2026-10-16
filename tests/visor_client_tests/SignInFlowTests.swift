// `/login` from the client's side: the session's state names the page to
// sign in at; while it does, what the user sends is the code — to the
// sign-in, nothing to the agent or the thread — and the `/login` that
// started it is no longer on its way.

import MessageCache
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

@MainActor
final class SignInFlowTests: XCTestCase {
    private var server: ScriptedServer!
    private var host: AgentServerConnection!

    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        server = ScriptedServer()
        ScriptedProvider.server = server
        AgentServerProviders.register(ScriptedProvider())
        VisorHost.settings = MemorySettings()
        host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example", provider: "scripted"))
        host.connect()
        for _ in 0..<50 { await Task.yield() }
    }

    func testWhileASignInWaitsTheNextWordsAreItsCode() async throws {
        let transcript = host.transcript(for: "S")
        let login = TranscriptEntry(id: "sending-login", role: .user, text: "/login")
        transcript.sending.append(.init(id: login.id, entry: login, sinceRevision: transcript.revision))

        var state = Envelope.ephemeral(session: "S", streams: [], status: [], activity: nil, busy: false, approval: nil, queued: [],
                                       notice: nil, signIn: "https://claude.ai/oauth/authorize?code=true")
        transcript.apply(state)
        XCTAssertEqual(transcript.signIn, "https://claude.ai/oauth/authorize?code=true")
        XCTAssertTrue(transcript.sending.isEmpty, "the /login is taken")

        host.sendMessage("S", text: " abc#s1 ")
        XCTAssertEqual(server.codes, ["abc#s1"])
        XCTAssertTrue(server.sent.isEmpty, "nothing for the agent")
        XCTAssertTrue(transcript.sending.isEmpty, "nothing in the thread")

        // A command still goes as a command.
        host.sendMessage("S", text: "/login --console")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(server.sent.map(\.1), ["/login --console"])

        // Done: what is sent next is a message again.
        state.signIn = nil
        transcript.apply(state)
        XCTAssertNil(transcript.signIn)
    }
}
