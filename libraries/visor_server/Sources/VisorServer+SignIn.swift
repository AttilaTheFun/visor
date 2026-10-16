// `/login` in a Claude session: Claude Code signed in again from wherever
// the user is, for when its sign-in expired (it said "Please run /login").
// The page to sign in at is the session's state until the sign-in ends;
// the code that page shows comes back as `signIn`. Signed in, the agent is
// made again on the new sign-in.

import Foundation
import VisorProtocol

extension VisorServer {
    /// What `/login` and its options are, when the words are that: the
    /// options for `claude auth login` (`--console`, `--sso`, `--email …`);
    /// `["cancel"]` to give up a sign-in under way.
    static func signInArguments(_ text: String) -> [String]? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.first == "/login" else { return nil }
        return Array(words.dropFirst())
    }

    /// The command that starts it, beside Claude Code's own.
    static let signInCommand = SlashCommand(name: "login", description: "Sign in to Claude again, from here (when its sign-in has expired)",
                                            argumentHint: "[--console]")

    func startSignIn(_ record: SessionRecord, arguments: [String]) {
        record.signIn?.cancel()
        record.signIn = nil
        if arguments == ["cancel"] { return broadcast(record.ephemeralEnvelope, session: record) }
        guard let claude = ToolPath.resolve("claude") else {
            return tell(record, "Claude Code is not installed on this computer.")
        }
        do {
            let signIn = try ClaudeSignIn(claude: claude, arguments: arguments, environment: ToolPath.environment())
            signIn.onURL = { [weak self, weak record] _ in
                guard let self, let record, record.signIn === signIn else { return }
                self.broadcast(record.ephemeralEnvelope, session: record)
            }
            signIn.onEnd = { [weak self, weak record] signedIn, said in
                guard let self, let record, record.signIn === signIn else { return }
                record.signIn = nil
                if signedIn {
                    self.tell(record, "Signed in to Claude again. The agent starts afresh on the new sign-in.")
                    if !record.info.archived { self.restartAgent(record) }
                } else {
                    self.tell(record, "The sign-in did not finish" + (said.isEmpty ? "." : ": " + said))
                }
            }
            record.signIn = signIn
            Self.log("sign-in for \(record.info.id) started")
        } catch {
            tell(record, "The sign-in could not start: \(error)")
        }
    }

    /// The code the sign-in page showed: to the sign-in under way.
    func performSignIn(_ envelope: Envelope) {
        guard let record = session(envelope.session), let code = envelope.text, !code.isEmpty else { return }
        record.signIn?.submit(code)
    }

    /// Tells the session's user something, as a notice.
    private func tell(_ record: SessionRecord, _ words: String) {
        if let envelope = record.apply(.notice(words)) { broadcast(envelope, session: record) }
    }
}
