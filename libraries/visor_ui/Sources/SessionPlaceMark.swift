import SwiftUI
import VisorProtocol

/// Where a session's agent runs, at the top of its row: a box for a Linux
/// container (one made for it, or the server's own that its sessions
/// share), else the computer's system — Apple's logo, a penguin for Linux,
/// a window for Windows. Nothing from a server that does not say.
@MainActor
struct SessionPlaceMark: View {
    let session: SessionInfo

    /// Whether there is a mark to show.
    static func shows(_ session: SessionInfo) -> Bool {
        session.container != nil || session.inContainer == true || ["macos", "linux", "windows"].contains(session.system ?? "")
    }

    var body: some View {
        if session.container != nil || session.inContainer == true {
            Image(systemName: "shippingbox").accessibilityLabel("In a container")
        } else {
            switch session.system {
            case "macos"?: Image(systemName: "applelogo").accessibilityLabel("On macOS")
            case "linux"?: Text("🐧").accessibilityLabel("On Linux")
            case "windows"?: Image(systemName: "squareshape.split.2x2").accessibilityLabel("On Windows")
            default: EmptyView()
            }
        }
    }
}
