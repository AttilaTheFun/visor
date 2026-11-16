import VisorProtocol

/// The person's answer to an `approve` call: allowed or not, a question's
/// answers, and, when nobody answered, why the call was given up
/// ("cancelled" by the agent, "unanswered" after 25 minutes).
package struct MCPAnswer: Equatable, Sendable {
    package let allow: Bool
    package let answers: JSONValue?
    package let reason: String?

    package init(allow: Bool, answers: JSONValue?, reason: String?) {
        self.allow = allow
        self.answers = answers
        self.reason = reason
    }

    package static let no = MCPAnswer(allow: false, answers: nil, reason: nil)
}
