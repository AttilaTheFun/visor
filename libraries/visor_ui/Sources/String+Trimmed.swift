import SwiftUI
import VisorClient
import VisorProtocol

extension String {
    var trimmed: String {
        var text = Substring(self)
        while let first = text.first, first.isWhitespace || first.isNewline { text = text.dropFirst() }
        while let last = text.last, last.isWhitespace || last.isNewline { text = text.dropLast() }
        return String(text)
    }
}
