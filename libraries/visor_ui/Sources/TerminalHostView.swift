import SwiftUI
import VisorClient
import VisorProtocol
#if canImport(SwiftTerm)
import Foundation
import SwiftTerm
#endif

#if canImport(SwiftTerm)
#if os(macOS)
import AppKit
typealias PlatformViewRepresentable = NSViewRepresentable
#else
import UIKit
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// The SwiftTerm view, wired to one session.
@MainActor
struct TerminalHostView: PlatformViewRepresentable {
    let host: AgentServerConnection
    let sessionID: String
    let transcript: SessionTranscript

    func makeCoordinator() -> Coordinator { Coordinator(host: host, sessionID: sessionID) }

    #if os(macOS)
    func makeNSView(context: Context) -> TerminalView { make(context) }
    func updateNSView(_ view: TerminalView, context: Context) {}
    #else
    func makeUIView(context: Context) -> TerminalView { make(context) }
    func updateUIView(_ view: TerminalView, context: Context) {}
    #endif

    private func make(_ context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        #if os(macOS)
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        #else
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        #endif
        // Everything the shell has shown goes into SwiftTerm's own
        // emulator; live bytes follow. A replay of the whole screen (this
        // window took the terminal, or subscribed again) starts it over.
        // The view resizes the far PTY as it lays out (sizeChanged), and
        // what runs there draws itself again for that size.
        for chunk in transcript.terminalBacklog { view.feed(chunk) }
        transcript.onTerminalBytes = { [weak view] chunk, startsOver in
            guard let view else { return }
            if startsOver { view.getTerminal().resetToInitialState() }
            view.feed(chunk)
        }
        return view
    }

    /// SwiftTerm calls its delegate on the main thread: what is typed is
    /// taken there as it comes, so it goes to the computer in the order
    /// it was typed.
    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let host: AgentServerConnection
        let sessionID: String
        init(host: AgentServerConnection, sessionID: String) {
            self.host = host
            self.sessionID = sessionID
        }
        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let base64 = Data(data).base64EncodedString()
            MainActor.assumeIsolated { host.sendInput(sessionID, data: base64) }
        }
        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            MainActor.assumeIsolated { host.resize(sessionID, cols: newCols, rows: newRows) }
        }
        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        nonisolated func bell(source: TerminalView) {}
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

private extension TerminalView {
    /// A base64 chunk of the PTY's output.
    func feed(_ base64: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        feed(byteArray: ArraySlice([UInt8](data)))
    }
}
#endif
