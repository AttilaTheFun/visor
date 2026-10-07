// What Apple's SwiftUI has and Isomer's does not yet: item-driven
// sheets (built on the isPresented form), a secure field, and the
// inset-grouped form style on the Mac.

import AgentUI
import SwiftUI

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

    /// Swipe actions on a list row, where rows swipe (not on a TV, whose
    /// rows have the context menu instead).
    @ViewBuilder func rowSwipeActions<Content: View>(edge: HorizontalEdge, allowsFullSwipe: Bool, @ViewBuilder content: () -> Content) -> some View {
        #if os(tvOS)
        self
        #else
        swipeActions(edge: edge, allowsFullSwipe: allowsFullSwipe, content: content)
        #endif
    }

    /// Text the user can select a line out of, where the system lets them.
    @ViewBuilder func selectableText() -> some View {
        #if os(tvOS)
        self
        #else
        textSelection(.enabled)
        #endif
    }

    /// The thread's bar (ThreadBar): the navigation bar's title and
    /// trailing control, or a TV's own row above the thread.
    func threadBar<Trailing: View>(title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        modifier(ThreadBar(title: title, trailing: trailing()))
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

/// The connection log handed to the system's share sheet as a text file
/// (AirDrop, Files, Mail), where there is one; nothing elsewhere, where
/// copying it is the way out.
@MainActor @ViewBuilder func connectionLogShareLink(_ text: String) -> some View {
    #if os(iOS) || os(macOS)
    ShareLink(item: ConnectionLogFile(text: text), preview: SharePreview("Visor connection log")) {
        Text("Share Connection Log")
    }
    #else
    EmptyView()
    #endif
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

/// The system pasteboard: AppKit's on the Mac, UIKit's everywhere else
/// (which the portable SwiftUI has too: the browser's clipboard, Android's).
func copyToPasteboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #elseif os(tvOS)
    // A TV has no pasteboard: nothing to copy to.
    _ = text
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
