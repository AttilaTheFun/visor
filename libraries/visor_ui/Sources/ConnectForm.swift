// Adding a computer: its connection code — copied from the Visor menu bar
// app on the Mac, or carried by the QR code a phone's camera scans — which
// holds the name, the address and the password. A bare Tailscale name
// works too, with the password typed beside it. Always TLS on 443 (the
// Mac's Tailscale Serve endpoint).

import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct ConnectForm: View {
    let connect: (HostConfig) -> Void
    @State private var entry = ""
    @State private var password = ""
    @State private var backendID = Backends.all.first?.id ?? "tailscale"
    private var backend: any Backend { Backends.backend(for: backendID) ?? TailscaleBackend() }
    /// What was typed or pasted, read as a connection code when it is one.
    private var code: ConnectionCode? { ConnectionCode(parsing: entry) }

    var body: some View {
        Form {
            Section {
                if Backends.all.count > 1 {
                    Picker("Backend", selection: $backendID) {
                        ForEach(Backends.all, id: \.id) { Text($0.title).tag($0.id) }
                    }
                }
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
                    TitledField(title: backend.passwordFieldTitle) {
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
            connect(HostConfig(name: code.name, host: code.host, password: code.password, backend: backend.id))
        } else {
            connect(HostConfig(name: entry.trimmed, host: entry.trimmed, password: password, backend: backend.id))
        }
    }
}

extension String {
    var trimmed: String {
        var text = Substring(self)
        while let first = text.first, first.isWhitespace || first.isNewline { text = text.dropFirst() }
        while let last = text.last, last.isWhitespace || last.isNewline { text = text.dropLast() }
        return String(text)
    }
}

extension View {
    /// The URL keyboard on a phone; nothing elsewhere.
    @ViewBuilder func keyboardTypeURL() -> some View {
        #if os(iOS)
        keyboardType(.URL).textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    @ViewBuilder func keyboardTypeNumbers() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }
}
