// A computer's connection codes, for another device to take: the QR code
// carries the `visor://` link, which opens Visor there and adds the
// computer, and each copy leads with one kind of path (HTTP, HTTPS, SSH).
// So one device that has a computer can hand it to another — the menu bar
// app to a Mac's client, that to a phone — without the computer's own
// screen. The codes are the server's own when it answers (`GET
// /api/codes`, the same the menu bar app shows: the address other devices
// reach it at, where this device may reach it on loopback); else they are
// made from what this device holds.

import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct ConnectionCodeSection: View {
    var host: AgentServerConnection
    @State private var shown = false
    /// The server's own codes, once asked for.
    @State private var fromServer: ConnectionCodes?

    private var record: AgentServerRecord { host.record }

    private var codes: ConnectionCodes? {
        if let fromServer { return fromServer }
        guard !record.secret.isEmpty, !record.address.isEmpty else { return nil }
        return ConnectionCodes(ConnectionCode(name: record.name.isEmpty ? record.address : record.name, host: record.address,
                                              password: record.secret, id: record.serverID, paths: record.paths))
    }

    var body: some View {
        Section {
            if let codes {
                Button(shown ? "Hide QR Code" : "Show QR Code") { shown.toggle() }
                    .accessibilityIdentifier("show-qr")
                if shown, let qr = QRCode(codes.link) {
                    QRCodeShape(code: qr)
                        .fill(Color.black)
                        .background(Color.white)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 280)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .accessibilityLabel("Connection code for \(record.name)")
                        .accessibilityIdentifier("qr-code")
                }
                ForEach(ConnectionPath.allCases, id: \.self) { kind in
                    if let code = codes.code(for: kind) {
                        Button("Copy \(kind.title) Connection Code") { copyToPasteboard(code) }
                            .accessibilityIdentifier("copy-\(kind.rawValue)-code")
                    }
                }
            } else {
                Text("This computer's password is not saved here, so there is no code to hand on.")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Connect another device")
        } footer: {
            Text("The same codes the computer's menu bar app shows. Scan the QR code with another device's camera, or paste a code into Visor there, to add this computer; each carries the address, the password and the other paths, so give it only to your own devices. A copy leads with its kind of path; the SSH code has the new device come in by another path once, hand its key over, and use SSH from then on.")
        }
        .task(id: host.state) {
            guard host.state == .connected, let codes = try? await host.connectionCodes() else { return }
            fromServer = codes
        }
    }
}
