// Signing Claude Code in again (`/login`) from a session's chat. The page
// to sign in at is offered once, in an alert that opens it; when the user
// comes back to Visor from it, the code the page showed is asked for in a
// sheet of its own (SignInCodeSheet), and asked for again each time they
// come back while it is still awaited. The code goes as the composer's does
// (AgentServerConnection.sendMessage: while a sign-in waits, the words sent
// are its code), and the composer still takes it too.

import Foundation
import SwiftUI
import VisorClient

extension View {
    /// The sign-in Claude Code waits on in `sessionID`, if any: its page
    /// offered, then its code asked for.
    func signInToClaude(host: AgentServerConnection, sessionID: String, transcript: SessionTranscript) -> some View {
        modifier(SignInToClaude(host: host, sessionID: sessionID, transcript: transcript))
    }
}

/// The alert that opens the sign-in page, and the prompt for its code.
@MainActor
private struct SignInToClaude: ViewModifier {
    let host: AgentServerConnection
    let sessionID: String
    let transcript: SessionTranscript
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    /// The sign-in page last offered: offered once.
    @State private var offered: String?
    /// The sign-in page opened from here: its code is asked for when the
    /// user is back.
    @State private var opened: String?
    /// Visor has left the foreground since the page was opened.
    @State private var away = false
    /// The prompt for the code is open.
    @State private var asking = false

    /// How long after the page opens the code is asked for where Visor
    /// is not seen to leave for it (nanoseconds).
    static let unseenLeaving: UInt64 = 1_000_000_000

    /// Whether the page opened from here still waits for its code, and
    /// none has been sent to it.
    private var awaitingCode: Bool {
        guard let page = transcript.signIn else { return false }
        return page == opened && transcript.signInCodeSent != page
    }

    /// Whether the page is still to be offered.
    private var offering: Bool {
        guard let page = transcript.signIn else { return false }
        return page != offered && transcript.signInCodeSent != page
    }

    func body(content: Content) -> some View {
        content
            .alert("Sign In to Claude", isPresented: Binding(get: { offering }, set: { if !$0 { offered = transcript.signIn } })) {
                Button("Open Sign-In Page") { open() }
                Button("Later", role: .cancel) { offered = transcript.signIn }
            } message: {
                Text("Sign in on the page that opens. Back in Visor, paste the code it shows.")
            }
            // A sheet, not an alert with a text field: an alert closes on
            // any of its buttons (Paste among them), and Isomer's lays its
            // content out in one row beside the buttons.
            .sheet(isPresented: $asking) {
                SignInCodeSheet { [host, sessionID] code in host.sendMessage(sessionID, text: code) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    if opened != nil { away = true }
                } else if away {
                    away = false
                    ask()
                }
            }
            // Signed in, given up, or begun again with another page: the
            // code is no longer the one asked for.
            .onChange(of: transcript.signIn) { _, _ in
                if !awaitingCode { asking = false }
            }
    }

    /// Opens the sign-in page. Where the platform does not say Visor left
    /// for it (a browser beside a Mac's window, the web, the headless
    /// client), the code is asked for a moment later instead of on the way
    /// back.
    private func open() {
        offered = transcript.signIn
        guard let page = transcript.signIn, let url = URL(string: page) else { return }
        opened = page
        away = false
        openURL(url)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.unseenLeaving)
            if !away { ask() }
        }
    }

    /// Asks for the code, if it is still awaited.
    private func ask() {
        guard awaitingCode else { return }
        asking = true
    }
}
