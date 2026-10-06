// An agent's account changing on the computer: the server says it on its
// own, and the client lays it on that agent's catalog.

@testable import VisorClient
import VisorProtocol
import XCTest

final class AccountEventTests: XCTestCase {
    func testAnAccountChangeIsAnEventOfItsOwn() throws {
        let account = AgentAccount(plan: "ChatGPT Pro", subscription: true,
                                   limits: [UsageLimit(name: "Weekly", used: 0.17, resets: 1_791_654_291),
                                            UsageLimit(name: "Credits", left: 62_500, unit: .credits)],
                                   updated: 1_791_000_000)
        guard case .account(let said, let agent)? = WireAgentServer.translate(Envelope.account(account, of: .codex).encoded()) else {
            return XCTFail("not an account event")
        }
        XCTAssertEqual(agent, .codex)
        XCTAssertEqual(said, account)
        // One without its agent is nothing to act on.
        var bare = Envelope(type: "account")
        bare.account = account
        XCTAssertNil(WireAgentServer.translate(bare.encoded()))
    }
}
