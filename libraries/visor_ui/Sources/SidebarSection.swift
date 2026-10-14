import SwiftUI

/// A section of the sidebar's list. Beside the detail its header is the
/// list's own; in one column (a phone) the header is the section's first
/// row instead, which scrolls away with the rows as Settings' group titles
/// do. A plain list's headers stay pinned under the navigation bar, and
/// with one there iOS draws a soft edge under the bar rather than the hard
/// band Messages and Settings have once their title is in the bar.
@MainActor
struct SidebarSection<Rows: View, Header: View>: View {
    let inline: Bool
    @ViewBuilder let rows: () -> Rows
    @ViewBuilder let header: () -> Header

    var body: some View {
        if inline {
            Section {
                header()
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .accessibilityAddTraits(.isHeader)
                rows()
            }
        } else {
            Section {
                rows()
            } header: {
                header()
            }
        }
    }
}
