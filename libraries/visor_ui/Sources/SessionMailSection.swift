// The session's inbox and outbox in its inspector (docs/agent-mail.md):
// what other sessions sent it, and what it sent them, each with who it is
// from or for, what became of it, and its words. Read from the server when
// the inspector shows the session, and again whenever either box changes
// (`mailChanged`). Nothing shows while both are empty.

import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct SessionMailSection: View {
    var host: AgentServerConnection
    let session: SessionInfo
    /// The newest this many of each box.
    static let shown = 20
    @State private var inbox: [MailMessage] = []
    @State private var outbox: [MailMessage] = []

    var body: some View {
        Group {
            if !inbox.isEmpty {
                Section(session.unreadMail > 0 ? "Inbox · \(session.unreadMail) unread" : "Inbox") {
                    ForEach(Array(inbox.suffix(Self.shown).reversed())) { message in
                        row(message, who: "From " + Self.name(message.from), state: Self.inboxState(message))
                    }
                }
            }
            if !outbox.isEmpty {
                Section("Outbox") {
                    ForEach(Array(outbox.suffix(Self.shown).reversed())) { message in
                        row(message, who: "To " + Self.name(message.to), state: Self.outboxState(message))
                    }
                }
            }
        }
        .task(id: "\(session.id) \(session.mailChanged ?? 0)") {
            guard let boxes = try? await host.mail(for: session.id) else { return }
            inbox = boxes.inbox
            outbox = boxes.outbox
        }
    }

    private func row(_ message: MailMessage, who: String, state: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(who).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(state).font(.caption).foregroundStyle(.secondary)
            }
            Text(message.text).font(.callout).lineLimit(4)
        }
        .padding(.vertical, 2)
    }

    /// A session by its name and computer.
    static func name(_ endpoint: RelayEndpoint) -> String {
        let session = endpoint.sessionName.isEmpty ? endpoint.session : endpoint.sessionName
        return endpoint.serverName.isEmpty ? session : "\(session) on \(endpoint.serverName)"
    }

    static func inboxState(_ message: MailMessage) -> String {
        message.unread ? "Unread" : "Read"
    }

    static func outboxState(_ message: MailMessage) -> String {
        switch message.state {
        case .waiting: "Waiting to be carried"
        case .delivered: "Delivered"
        case .read: "Read"
        case .failed: "Not taken"
        case .expired: "Expired"
        }
    }
}
