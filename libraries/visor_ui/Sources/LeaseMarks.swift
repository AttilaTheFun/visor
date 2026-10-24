import SwiftUI
import VisorProtocol

/// The machines a session leases from its server's oss, at the foot of its
/// row: each its kind's mark and name, faint until it is ready.
@MainActor
struct LeaseMarks: View {
    let leases: [SessionLease]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(leases, id: \.id) { lease in
                HStack(spacing: 3) {
                    Self.mark(lease.platform)
                    Text(Self.name(lease.platform))
                }
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .opacity(lease.state == "ready" ? 1 : 0.5)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(Self.name(lease.platform)) leased, \(lease.state)")
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder static func mark(_ platform: String) -> some View {
        switch platform {
        case "ios": Image(systemName: "iphone")
        case "android": Image(systemName: "candybarphone")
        case "macos": Image(systemName: "applelogo")
        case "linux": Text("🐧")
        case "windows": Image(systemName: "squareshape.split.2x2")
        default: Image(systemName: "desktopcomputer")
        }
    }

    static func name(_ platform: String) -> String {
        switch platform {
        case "ios": "iOS"
        case "android": "Android"
        case "macos": "macOS"
        case "linux": "Linux"
        case "windows": "Windows"
        default: platform
        }
    }
}
