// What Apple's SwiftUI has and a portable SwiftUI may not yet: item-driven
// sheets (built on the isPresented form), a secure field, and the
// inset-grouped form style on the Mac.

import AgentUI
import Foundation
import SwiftUI
#if canImport(QuickLook)
import QuickLook
#endif

/// What differs by platform outside a view modifier.
enum Compat {
    /// Where the window's one trailing pane goes (VisorRootView): the
    /// detail column on a Mac, the whole split view elsewhere.
    static var paneOnDetailColumn: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Whether an exported session is saved at once (the Mac's save
    /// panel), rather than waiting for Save… or Share… (a phone's).
    static var savesExportAtOnce: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Leave to read a file the person picked where it lies: Apple's
    /// sandbox's security scope, which Apple's Foundation alone has.
    /// Whether it was given, for endFileAccess.
    static func beginFileAccess(_ url: URL) -> Bool {
        #if canImport(Darwin)
        url.startAccessingSecurityScopedResource()
        #else
        false
        #endif
    }

    static func endFileAccess(_ url: URL, _ began: Bool) {
        #if canImport(Darwin)
        if began { url.stopAccessingSecurityScopedResource() }
        #endif
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

    /// The sidebar's list: rows on the list's own ground, a row filled
    /// only while it is selected or pressed — the system's sidebar beside
    /// the detail (with its rounded selection), a plain list in one column,
    /// as Messages has them; never cards, which the sidebar style turns
    /// into in one column.
    @ViewBuilder func sidebarListStyle(compact: Bool) -> some View {
        if compact {
            listStyle(.plain)
        } else {
            listStyle(.sidebar)
        }
    }

    /// A list in the detail (an archive): inset grouped, as every SwiftUI
    /// draws it (a portable SwiftUI's on a phone too), and the sidebar
    /// style on the Mac, which has no inset-grouped list.
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
    /// No wider than a window of the content's least (320), opened at 360.
    @ViewBuilder func choiceListInSheet(rows: Int) -> some View {
        #if os(macOS)
        frame(minWidth: 320, idealWidth: 360, minHeight: CGFloat(rows) * 32 + 24)
        #else
        self
        #endif
    }

    /// The chat's column on the Mac: no minimum width of its own, so its
    /// column's is the split view's (320, VisorRootView) and the rows and the composer fit
    /// what they get. With the chat's own minimum (its composer's buttons
    /// and command, the rows' fixed pieces), opening the inspector on a
    /// screen too narrow for the three columns set the split view raising
    /// and lowering the detail's minimum until AppKit gave up on the window
    /// (visor#240: a 1024-point screen). Elsewhere the chat as it is: on the
    /// iPhone the same frame kept a thread with a goal laying itself out
    /// in landscape, never settling (0.46's proof).
    @ViewBuilder func chatColumn() -> some View {
        #if os(macOS)
        frame(minWidth: 0, maxWidth: .infinity)
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

/// The file at `url` handed to the iPhone's share sheet (AirDrop, Mail,
/// Files); elsewhere nothing, Save… being the way. (A portable SwiftUI's
/// ShareLink shares a link's text, not its file.)
@MainActor @ViewBuilder func shareFileLink(_ url: URL) -> some View {
    #if os(iOS)
    ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
        .accessibilityIdentifier("export-share")
    #else
    EmptyView()
    #endif
}

extension View {
    /// A sheet's heights on a phone (and on the portable SwiftUI, whose
    /// sheets are a phone's); a window's size on the Mac: opened at its
    /// ideal, and no wider at its least than a window of the content's
    /// least (320, VisorRootView).
    @ViewBuilder func presentationDetentsLarge() -> some View {
        #if os(macOS)
        frame(minWidth: 320, idealWidth: 520, minHeight: 560)
        #else
        presentationDetents([.large])
        #endif
    }

    @ViewBuilder func presentationDetentsMediumLarge() -> some View {
        #if os(macOS)
        frame(minWidth: 320, idealWidth: 440, minHeight: 380)
        #else
        presentationDetents([.medium, .large])
        #endif
    }
}
