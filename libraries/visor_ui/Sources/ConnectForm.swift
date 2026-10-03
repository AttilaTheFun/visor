// Adding a Mac (the Tailscale provider's sign-in): its connection code — copied from the Visor menu bar
// app on the Mac, or carried by the QR code a phone's camera scans — which
// holds the name, the address and the password. A bare Tailscale name
// works too, with the password typed beside it. Always TLS on 443 (the
// Mac's Tailscale Serve endpoint).

import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct ConnectForm: View {
    let connect: (AgentServerRecord) -> Void
    @State private var entry = ""
    @State private var password = ""
    /// What was typed or pasted, read as a connection code when it is one.
    private var code: ConnectionCode? { ConnectionCode(parsing: entry) }

    var body: some View {
        Form {
            Section {
                TitledField(title: "Connection code") {
                    TextField("Paste the code, or type a Tailscale name", text: $entry)
                        .autocorrectionDisabled()
                        .keyboardTypeURL()
                        .accessibilityIdentifier("host")
                }
                if code == nil {
                    // Read only when tapped: a phone asks before an app
                    // reads the pasteboard.
                    Button("Paste Connection Code") {
                        if let pasted = pasteboardString() { entry = pasted.trimmed }
                    }
                    .accessibilityIdentifier("paste-code")
                }
                if let code {
                    Text("\(code.name) at \(code.host)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else if !entry.trimmed.isEmpty {
                    TitledField(title: "Password (if asked)") {
                        PasswordField("Only if the computer asks", text: $password)
                            .accessibilityIdentifier("password")
                    }
                }
            } header: {
                Text("Computer")
            } footer: {
                Text("In the Visor menu bar app on the Mac: Copy Connection Code, or open Settings and scan its QR code with this device's camera.")
            }
            Section {
                Button("Connect", action: submit)
                    .disabled(entry.trimmed.isEmpty)
                    .accessibilityIdentifier("connect")
            }
        }
        .insetGroupedForm()
        .onSubmit(submit)
    }

    private func submit() {
        guard !entry.trimmed.isEmpty else { return }
        if let code {
            connect(AgentServerRecord(name: code.name, address: code.host, secret: code.password))
        } else {
            connect(AgentServerRecord(name: entry.trimmed, address: entry.trimmed, secret: password))
        }
    }
}
