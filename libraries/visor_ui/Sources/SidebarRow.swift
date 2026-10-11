import SwiftUI

/// A row of the sidebar, laid out the same in every section: its content
/// 24pt in from the row's edges. A row that selects is tagged for the
/// list's selection and, while it is the one selected, draws the
/// highlight itself — the accent color, 12pt in from the row's sides (so
/// 12pt around the content) and 4pt from its top and bottom (so its
/// corners show in a section's first and last rows too), with 8pt
/// corners — its content in white. The row draws its own background
/// either way (`listRowBackground`), which is what keeps the system's own
/// selection look from showing: the grouped list's fill, and the
/// highlight on it.
struct SidebarRow: ViewModifier {
    let selected: Bool

    static let margin: CGFloat = 12
    static let radius: CGFloat = 8
    static let gap: CGFloat = 4

    func body(content: Content) -> some View {
        inset(content.foregroundStyle(selected ? Color.white : Color.primary))
            .listRowBackground(ZStack {
                Color.groupedRowFill
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.clear)
                    .padding(.horizontal, Self.margin)
                    .padding(.vertical, Self.gap)
            })
    }

    /// The content's sides in from the row's; its top and bottom as the
    /// list has them (before the Mac's 26, which cannot leave them, 4pt).
    @ViewBuilder private func inset(_ row: some View) -> some View {
        if #available(iOS 26, macOS 26, *) {
            row.listRowInsets(.horizontal, 2 * Self.margin)
        } else {
            row.listRowInsets(EdgeInsets(top: 4, leading: 2 * Self.margin, bottom: 4, trailing: 2 * Self.margin))
        }
    }
}

extension View {
    /// A sidebar row that selects `tag`, highlighted while `selection` is it.
    func sidebarRow(_ tag: ContentSelection, selection: ContentSelection?) -> some View {
        self.tag(tag).modifier(SidebarRow(selected: selection == tag))
    }

    /// A sidebar row that does not select: laid out as the others.
    func sidebarRow() -> some View {
        modifier(SidebarRow(selected: false))
    }
}
