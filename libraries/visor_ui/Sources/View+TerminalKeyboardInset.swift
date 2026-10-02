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
#else
import UIKit
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
#endif
