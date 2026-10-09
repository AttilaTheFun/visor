// What Apple's SwiftUI has and Isomer's does not yet: item-driven
// sheets (built on the isPresented form), a secure field, and the
// inset-grouped form style on the Mac.

import AgentUI
import SwiftUI
#if canImport(QuickLook)
import QuickLook
#endif

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

    /// The sidebar's list: inset grouped, as every SwiftUI draws it (the
    /// web's and Isomer's on a phone too), and the sidebar style on the Mac.
    @ViewBuilder func insetGroupedList() -> some View {
        // The Mac's SwiftUI has no inset-grouped list: its sidebar is the
        // same thing there. Every other SwiftUI draws inset-grouped.
        #if os(macOS)
        listStyle(.sidebar)
        #else
        listStyle(.insetGrouped)
        #endif
    }

    /// A short list of choices in a sheet: on the Mac a sheet gives a list
    /// no height of its own, and it draws at none; a floor of a row each
    /// (plus the chrome) shows it. A phone's sheet fills the screen anyway.
    @ViewBuilder func choiceListInSheet(rows: Int) -> some View {
        #if os(macOS)
        frame(minWidth: 360, minHeight: CGFloat(rows) * 32 + 24)
        #else
        self
        #endif
    }

    /// The system's preview of a file (Quick Look: pictures zoom, videos
    /// play, documents open), where the system has one; nothing elsewhere.
    @ViewBuilder func filePreview(_ file: Binding<URL?>) -> some View {
        #if canImport(QuickLook)
        quickLookPreview(file)
        #else
        self
        #endif
    }

    /// A section header as written, not upper-cased.
    @ViewBuilder func noHeaderCase() -> some View {
        textCase(nil)
    }
}

/// The connection log handed to the system's share sheet as text (Mail,
/// Messages, Notes; the web's share or clipboard, Android's chooser), the
/// same on every SwiftUI.
@MainActor func connectionLogShareLink(_ text: String) -> some View {
    ShareLink(item: text, preview: SharePreview("Visor connection log")) {
        Text("Share Connection Log")
    }
}

/// What the system pasteboard holds as text: AppKit's on the Mac, UIKit's
/// everywhere else (which the portable SwiftUI has too).
@MainActor func pasteboardString() -> String? {
    #if os(macOS)
    return NSPasteboard.general.string(forType: .string)
    #else
    return UIPasteboard.general.string
    #endif
}

/// The system pasteboard: AppKit's on the Mac, UIKit's everywhere else
/// (which the portable SwiftUI has too: the browser's clipboard, Android's).
func copyToPasteboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

extension View {
    /// A sheet's heights on a phone (and on the portable SwiftUI, whose
    /// sheets are a phone's); a window's size on the Mac.
    @ViewBuilder func presentationDetentsLarge() -> some View {
        #if os(macOS)
        frame(minWidth: 520, minHeight: 560)
        #else
        presentationDetents([.large])
        #endif
    }

    @ViewBuilder func presentationDetentsMediumLarge() -> some View {
        #if os(macOS)
        frame(minWidth: 440, minHeight: 380)
        #else
        presentationDetents([.medium, .large])
        #endif
    }
}

#if os(iOS)
import UIKit

extension View {
    /// The camera, as Isomer spells it on the portable SwiftUI (which
    /// has its own): a photo taken, as a file, or nil when cancelled.
    func cameraCapture(isPresented: Binding<Bool>, onCapture: @escaping (URL?) -> Void) -> some View {
        fullScreenCover(isPresented: isPresented) {
            CameraCapture { data in
                isPresented.wrappedValue = false
                guard let data else { return onCapture(nil) }
                let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("photo-\(UUID().uuidString.prefix(8)).jpg")
                onCapture((try? data.write(to: file)) != nil ? file : nil)
            }
            .ignoresSafeArea()
        }
    }
}
#endif
