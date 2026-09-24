// What Apple's SwiftUI has and universal_ui's does not yet: item-driven
// sheets (built on the isPresented form), a secure field, and the
// inset-grouped form style on the Mac.

import AgentUI
import SwiftUI

/// A password field: SecureField where there is one, a plain field elsewhere.
struct PasswordField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        #if canImport(UIKit) || canImport(AppKit)
        SecureField(title, text: $text)
        #else
        TextField(title, text: $text)
        #endif
    }
}

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

extension View {
    /// The inset-grouped form: iOS's default; the Mac's needs asking, and a
    /// width cap so the cells do not run edge to edge in a wide detail.
    @ViewBuilder func insetGroupedForm() -> some View {
        #if os(macOS)
        formStyle(.grouped).frame(maxWidth: 560)
        #else
        self
        #endif
    }

    /// A sheet for an optional item, on every SwiftUI.
    func itemSheet<Item: Identifiable, Content: View>(_ item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })) {
            if let value = item.wrappedValue { content(value) }
        }
    }

    /// A button's label as a list row: it fills the cell, so the whole row
    /// is the target. Paired with `.buttonStyle(.plain)`, which keeps a host
    /// from drawing a bordered control inside the cell — the shape for a row
    /// that ACTS. A row that SELECTS is `List(selection:)` and a `.tag`.
    func rowLabel() -> some View {
        frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    /// A section heading's own inset. The Mac's sidebar list runs its
    /// headers to the column's edge, so an accessory at the trailing edge
    /// needs the room the rows have.
    @ViewBuilder func headingInset() -> some View {
        #if os(macOS)
        padding(.trailing, 6)
        #else
        self
        #endif
    }

    /// A plain list without lines between the rows, the same everywhere:
    /// the sidebar groups itself, so it wants no help from a list style.
    @ViewBuilder func groupedRows() -> some View {
        #if canImport(UIKit) || canImport(AppKit)
        // Rows as tall as what is in them: Apple's List otherwise pads
        // every row to a minimum of 44pt.
        listStyle(.plain).listRowSeparator(.hidden).environment(\.defaultMinListRowHeight, 0)
        #else
        listStyle(.plain).listRowSeparator(.hidden)
        #endif
    }

    /// The sidebar's list: inset grouped on a phone, the sidebar style on
    /// the Mac, plain where neither exists.
    @ViewBuilder func insetGroupedList() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #elseif os(macOS)
        listStyle(.sidebar)
        #else
        listStyle(.plain)
        #endif
    }

    /// A section header as written, not upper-cased.
    @ViewBuilder func noHeaderCase() -> some View {
        #if canImport(UIKit) || canImport(AppKit)
        textCase(nil)
        #else
        self
        #endif
    }
}

/// What the system pasteboard holds as text, where there is one.
@MainActor func pasteboardString() -> String? {
    #if os(iOS)
    return UIPasteboard.general.string
    #elseif os(macOS)
    return NSPasteboard.general.string(forType: .string)
    #else
    return nil
    #endif
}

/// The system pasteboard, where there is one.
func copyToPasteboard(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

extension View {
    @ViewBuilder func presentationDetentsLarge() -> some View {
        #if os(iOS)
        presentationDetents([.large])
        #else
        frame(minWidth: 520, minHeight: 560)
        #endif
    }

    @ViewBuilder func presentationDetentsMediumLarge() -> some View {
        #if os(iOS)
        presentationDetents([.medium, .large])
        #else
        frame(minWidth: 440, minHeight: 380)
        #endif
    }
}

/// A picture from base64 bytes. Apple decodes them; the portable SwiftUI
/// hands the browser a data URL, which is the one thing every browser
/// already knows how to draw.
@MainActor
struct Base64Image: View {
    let base64: String
    /// The longest side it may take; 0 for as much room as there is. A
    /// picture is given exactly its own shape at that size, so nothing
    /// around it is empty box — which is what left tall screenshots
    /// floating in the middle and the rounded corner clipping nothing.
    var maxEdge: CGFloat = 0

    /// The size to draw at, from the picture's own and the room allowed —
    /// the transcript's rule, so the frame it reserved from the size it
    /// knew in advance is exactly the frame the picture takes.
    private func size(for pixels: CGSize) -> CGSize? {
        TranscriptMetrics.fitted(pixels, maxEdge: maxEdge)
    }

    var body: some View {
        // The picture's own proportions go on the view, so a frame around
        // it hugs the picture instead of letterboxing it — otherwise a
        // rounded corner is cut off empty space and never shows.
        #if os(iOS)
        if let data = Data(base64Encoded: base64), let image = UIImage(data: data) {
            drawn(Image(uiImage: image), pixels: image.size)
        } else {
            Color.secondary.opacity(0.15)
        }
        #elseif os(macOS)
        if let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
            drawn(Image(nsImage: image), pixels: image.size)
        } else {
            Color.secondary.opacity(0.15)
        }
        #else
        // A browser keeps a picture's proportions under a maximum rather
        // than padding it out to a box, so the limit can go straight on.
        AsyncImage(url: URL(string: "data:image/png;base64," + base64)) { image in
            image.resizable().aspectRatio(contentMode: .fit)
        } placeholder: {
            Color.secondary.opacity(0.15)
        }
        .frame(maxWidth: maxEdge > 0 ? maxEdge : nil, maxHeight: maxEdge > 0 ? maxEdge : nil)
        #endif
    }

    #if os(iOS) || os(macOS)
    /// At exactly its own shape when a size was asked for, and filling
    /// what it is given when one was not.
    @ViewBuilder private func drawn(_ image: Image, pixels: CGSize) -> some View {
        if let size = size(for: pixels) {
            image.resizable().frame(width: size.width, height: size.height)
        } else {
            image.resizable().aspectRatio(pixels.width / max(pixels.height, 1), contentMode: .fit)
        }
    }
    #endif
}
