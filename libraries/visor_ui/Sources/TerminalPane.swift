// A terminal session's shell: SwiftTerm fed the PTY's bytes as they arrive,
// keystrokes and resizes sent back. Where SwiftTerm does not run, the
// pane says so; a host that carries the client elsewhere brings its own.

import SwiftUI
import VisorClient
import VisorProtocol
#if canImport(SwiftTerm)
import Foundation
import SwiftTerm
#endif

@MainActor
struct TerminalPane: View {
    @ObservedObject var host: AgentServerConnection
    let sessionID: String

    var body: some View {
        #if canImport(SwiftTerm)
        TerminalHostView(host: host, sessionID: sessionID, transcript: host.transcript(for: sessionID))
            .background(Color.black)
            .terminalKeyboardInset()
        #else
        VStack(spacing: 8) {
            Image(systemName: "terminal").font(.largeTitle).foregroundColor(.secondary)
            Text("Terminals are not drawn on this platform yet.").foregroundColor(.secondary)
            Text("Open this session on a Mac or an iPhone.").font(.footnote).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}
