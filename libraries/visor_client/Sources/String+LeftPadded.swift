import SwiftUI
import MessageCache
import VisorProtocol
import VisorServices

extension String {
    func leftPadded(_ width: Int) -> String { count >= width ? self : String(repeating: "0", count: width - count) + self }
}
