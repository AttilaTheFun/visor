import AgentUI
import SwiftUI

/// A form cell: the title above the field, the way Settings lays out a
/// single-field row. Inset-grouped forms keep these to a readable width.
struct TitledField<Field: View>: View {
    let title: String
    @ViewBuilder let field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            field()
                .textFieldStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}
