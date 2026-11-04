import VisorProtocol

/// The person's answer to an `approve` call: allowed or not, a question's
/// answers, and, when nobody answered, why the call was given up
/// ("cancelled" by the agent, "unanswered" after 25 minutes).
struct MCPAnswer: Equatable, Sendable {
    let allow: Bool
    let answers: JSONValue?
    let reason: String?

    static let no = MCPAnswer(allow: false, answers: nil, reason: nil)
}
