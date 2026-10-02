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
