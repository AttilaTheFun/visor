// A session's terminal: SwiftTerm fed the PTY's bytes as they arrive,
// keystrokes and resizes sent back. Where SwiftTerm does not run, the
// pane says so; a host that carries the client elsewhere brings its own.

import SwiftUI
import VisorClient
import VisorProtocol
#if canImport(SwiftTerm)
import Foundation
import SwiftTerm
#endif

/// The terminal's own measurements: what a space of so many points holds
/// in cells, so a client can say what window it is taking control with
/// before any terminal exists to ask.
enum TerminalMetrics {
    static let fontSize: CGFloat = 13

    static func cells(in size: CGSize) -> (cols: Int, rows: Int) {
        #if canImport(UIKit)
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        let line = font.lineHeight
        #elseif canImport(AppKit)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        let line = font.ascender - font.descender + font.leading
        #else
        let advance: CGFloat = 8
        let line: CGFloat = 17
        #endif
        guard advance > 0, line > 0 else { return (80, 24) }
        return (max(20, Int(size.width / advance)), max(5, Int(size.height / line)))
    }
}

@MainActor
struct TerminalPane: View {
    @ObservedObject var host: HostConnection
    let sessionID: String

    var body: some View {
        #if canImport(SwiftTerm)
        TerminalHostView(host: host, sessionID: sessionID, transcript: host.transcript(for: sessionID))
            .background(Color.black)
            .terminalKeyboardInset()
        #else
        VStack(spacing: 8) {
            Image(systemName: "terminal").font(.largeTitle).foregroundColor(.secondary)
            Text("The terminal is not drawn on this platform yet.").foregroundColor(.secondary)
            Text("Switch the display to Chat in the session's inspector.").font(.footnote).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}

#if canImport(SwiftTerm)
#if os(macOS)
import AppKit
typealias PlatformViewRepresentable = NSViewRepresentable
#else
import UIKit
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

extension View {
    /// The pane shortened by the keyboard as it moves, with the keyboard's
    /// own animation: SwiftUI does not inset a UIKit view for it.
    @ViewBuilder func terminalKeyboardInset() -> some View {
        #if canImport(UIKit)
        modifier(TerminalKeyboardInset())
        #else
        self
        #endif
    }
}

#if canImport(UIKit)
private struct TerminalKeyboardInset: ViewModifier {
    @State private var inset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, inset)
            .ignoresSafeArea(.keyboard)
            .task {
                // The keyboard's frames as it moves, read where each is
                // announced; only the frame and its timing come here.
                let endKey = UIResponder.keyboardFrameEndUserInfoKey
                let durationKey = UIResponder.keyboardAnimationDurationUserInfoKey
                let moves = NotificationCenter.default.notifications(named: UIResponder.keyboardWillChangeFrameNotification)
                    .compactMap { note -> (end: CGRect, duration: Double)? in
                        guard let end = (note.userInfo?[endKey] as? NSValue)?.cgRectValue else { return nil }
                        return (end, (note.userInfo?[durationKey] as? Double) ?? 0.25)
                    }
                for await move in moves {
                    guard let screen = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.screen.bounds
                    else { continue }
                    // The part of the screen the keyboard covers, from the bottom.
                    let covered = max(0, screen.maxY - move.end.minY)
                    withAnimation(.easeOut(duration: move.duration)) { inset = covered }
                }
            }
    }
}
#endif

/// The SwiftTerm view, wired to one session.
@MainActor
struct TerminalHostView: PlatformViewRepresentable {
    let host: HostConnection
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
        // Everything the terminal has shown goes into SwiftTerm's own
        // emulator, which reflows to the view's width; live bytes follow.
        // The view resizes the far PTY as it lays out (sizeChanged), and
        // the agent repaints its current screen for that width.
        for chunk in transcript.terminalBacklog { view.feed(chunk) }
        transcript.onTerminalBytes = { [weak view] chunk in view?.feed(chunk) }
        return view
    }

    /// SwiftTerm calls its delegate on the main thread: what is typed is
    /// taken there as it comes, so it goes to the computer in the order
    /// it was typed.
    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let host: HostConnection
        let sessionID: String
        init(host: HostConnection, sessionID: String) {
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
