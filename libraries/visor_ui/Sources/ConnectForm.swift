// Adding a computer (a Visor server's sign-in): its connection code —
// copied from the Visor menu bar app on the Mac, or carried by the QR
// code a phone's camera scans — which holds the name, the address and
// the password. An address works too, with the password typed beside it:
// a name on a network (HTTPS at the root), the URL a proxy, a tunnel or
// a port gives (`ServerAddress`), or `user@host` for the computer's own
// SSH (`SSHAddress`), with this device's key shown to authorize there.

import SwiftUI
import VisorClient
import VisorProtocol
import VisorServices

@MainActor
struct ConnectForm: View {
    let connect: (AgentServerRecord) -> Void
    @State private var entry = ""
    @State private var password = ""
    /// What was typed or pasted, read as a connection code when it is one.
    private var code: ConnectionCode? { ConnectionCode(parsing: entry) }
    /// What was typed, read as an SSH address when it is one.
    private var ssh: SSHAddress? { code == nil ? SSHAddress(entry) : nil }

    var body: some View {
        Form {
            Section {
                TitledField(title: "Connection code") {
                    TextField("Paste the code, or type an address", text: $entry)
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
                    Text("\(code.name) at \(ServerAddress(code.host)?.display ?? code.host)")
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
                Text(ssh != nil && VisorHost.ssh == nil
                     ? "This app cannot reach a computer over SSH; use its connection code or a URL."
                     : "In the Visor menu bar app on the Mac: Copy Connection Code, or open Settings and scan its QR code with this device's camera. Or type where the server is reached: a URL such as http://192.168.1.20:7433 or https://proxy.example.com/visor, a name (HTTPS), or user@host for the computer's own SSH (through a jump host: user@host?via=user@jump).")
            }
            if ssh != nil, VisorHost.ssh != nil { DeviceKeySection() }
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
        guard !entry.trimmed.isEmpty, ssh == nil || VisorHost.ssh != nil else { return }
        if let code {
            connect(AgentServerRecord(name: code.name, address: code.host, secret: code.password))
        } else {
            connect(AgentServerRecord(name: entry.trimmed, address: entry.trimmed, secret: password))
        }
    }
}
