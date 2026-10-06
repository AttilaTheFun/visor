// A computer's connection code, from what this device already knows of
// it, for another device to scan: the QR code carries the `visor://`
// link, which opens Visor there and adds the computer. So one device that
// has a computer can hand it to another — a phone set up again from a
// Mac, say — without the computer's own screen.

import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct ConnectionCodeSection: View {
    let record: AgentServerRecord
    @State private var shown = false

    private var code: ConnectionCode? {
        guard !record.secret.isEmpty, !record.address.isEmpty else { return nil }
        return ConnectionCode(name: record.name.isEmpty ? record.address : record.name, host: record.address, password: record.secret)
    }

    var body: some View {
        Section {
            if let code {
                Button(shown ? "Hide QR Code" : "Show QR Code") { shown.toggle() }
                    .accessibilityIdentifier("show-qr")
                if shown, let qr = QRCode(code.link) {
                    QRCodeShape(code: qr)
                        .fill(Color.black)
                        .background(Color.white)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 280)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .accessibilityLabel("Connection code for \(code.name)")
                        .accessibilityIdentifier("qr-code")
                }
                Button("Copy Connection Code") { copyToPasteboard(code.encoded) }
            } else {
                Text("This computer's password is not saved here, so there is no code to hand on.")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Connect another device")
        } footer: {
            Text("Scan the QR code with another device's camera to add this computer there; it carries the address and the password, so show it only to your own devices.")
        }
    }
}
