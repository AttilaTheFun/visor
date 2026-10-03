// A terminal session's shell: AgentUI's TerminalScreenView, drawn in
// SwiftUI on every platform, fed the PTY's bytes as they arrive; what is
// typed and the window's size in cells go back to the computer.
//
// Shown, it takes the terminal for this window — once the view has
// measured itself, so the shell starts (or is resized) at exactly the
// window's size in cells — when no window has it, or when the user chose
// Use Here; never from another window otherwise. Again after a reconnect,
// when the computer forgot whose it was.

import Foundation
import SwiftUI
import TerminalUI
import VisorClient
import VisorProtocol

@MainActor
struct TerminalPane: View {
    @ObservedObject var host: AgentServerConnection
    let sessionID: String
    /// The user chose to take it from another window.
    let useHere: Bool
    @StateObject private var screen = TerminalScreen()
    /// Taking it from another window, until it is this one's.
    @State private var takingOver = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        TerminalScreenView(screen: screen, keyBar: sizeClass == .compact, paste: { pasteboardString() })
            .background(Color.black)
            .onAppear {
                takingOver = useHere
                attach()
            }
            .onChange(of: host.state) { _, state in if state == .connected { claim() } }
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
        screen.onResize = { _, _ in claim() }
        claim()
    }

    /// This window's size to the computer: a resize when the terminal is
    /// this window's; taking it when no window has it or the user asked.
    /// Nothing until the view has measured itself.
    private func claim() {
        guard screen.sized, host.state == .connected, let info = host.sessions.first(where: { $0.id == sessionID }) else { return }
        if host.controlsTerminal(info) {
            takingOver = false
            host.resize(sessionID, cols: screen.cols, rows: screen.rows)
        } else if !info.mode.isTUI || takingOver {
            host.assumeControl(sessionID, cols: screen.cols, rows: screen.rows)
        }
    }

    /// A base64 chunk of the PTY's output.
    static func bytes(_ base64: String) -> [UInt8] {
        Data(base64Encoded: base64).map { [UInt8]($0) } ?? []
    }
}
