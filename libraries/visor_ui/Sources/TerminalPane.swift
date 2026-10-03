// A terminal session's shell: AgentUI's TerminalScreenView, drawn in
// SwiftUI on every platform, fed the PTY's bytes as they arrive; what is
// typed and the window's size in cells go back to the computer.

import Foundation
import SwiftUI
import TerminalUI
import VisorClient
import VisorProtocol

@MainActor
struct TerminalPane: View {
    @ObservedObject var host: AgentServerConnection
    let sessionID: String
    @StateObject private var screen = TerminalScreen()
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        TerminalScreenView(screen: screen, keyBar: sizeClass == .compact, paste: { pasteboardString() })
            .background(Color.black)
            .onAppear(perform: attach)
    }

    /// What the shell has shown so far into the screen, then each chunk as
    /// it comes; typing and the size in cells back out.
    private func attach() {
        let transcript = host.transcript(for: sessionID)
        screen.startOver()
        for chunk in transcript.terminalBacklog { screen.feed(Self.bytes(chunk)) }
        transcript.onTerminalBytes = { [weak screen] chunk, startsOver in
            guard let screen else { return }
            if startsOver { screen.startOver() }
            screen.feed(Self.bytes(chunk))
        }
        let host = host, sessionID = sessionID
        screen.onInput = { bytes in host.sendInput(sessionID, data: Data(bytes).base64EncodedString()) }
        screen.onResize = { cols, rows in host.resize(sessionID, cols: cols, rows: rows) }
        // The size it has now, in case it was laid out before this ran.
        host.resize(sessionID, cols: screen.cols, rows: screen.rows)
    }

    /// A base64 chunk of the PTY's output.
    static func bytes(_ base64: String) -> [UInt8] {
        Data(base64Encoded: base64).map { [UInt8]($0) } ?? []
    }
}
