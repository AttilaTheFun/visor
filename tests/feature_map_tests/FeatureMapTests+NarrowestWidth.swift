// The content at its narrowest, 320 points wide (Logan, 27 Nov 2026: the
// narrowest an iPad app gets in Stage Manager, and the Mac window's least):
// the chat with its composer, and the session's details, each laid out
// within the window, nothing running off its side. Headless alone, where
// the window's width is the test's.

import IsomerHeadless
import Testing

extension FeatureMapTests {
    @Suite("Narrowest width", .enabled(if: VisorLaunch.headless, "a headful device's width is its own"))
    struct NarrowestWidth {
        static let width = Double(VisorLaunch.Width.narrowest.size.width)

        @Test("Session chat at 320 points: its rows and composer within the window")
        func chat() throws {
            let app = try VisorLaunch.fixture("chat", width: .narrowest)
            defer { app.quit() }
            try app.screen(within: 15) { FeatureMapNode.chat.isShown(on: $0) }
            let layout = try app.layout()
            #expect(layout.width == Self.width, "the window: \(layout.width) by \(layout.height)")
            #expect(layout.items.contains { $0.label == "Message Claude Code" || $0.identifier == "model" },
                    "the composer is laid out: \(Self.listing(layout))")
            let out = Self.outside(layout)
            #expect(out.isEmpty, "off the window's side: \(Self.listing(out))")
        }

        @Test("Session details at 320 points: within the window")
        func details() throws {
            let app = try VisorLaunch.fixture("inspector", width: .narrowest)
            defer { app.quit() }
            try app.screen(within: 15) { FeatureMapNode.details.isShown(on: $0) }
            let layout = try app.layout()
            #expect(layout.items.contains { $0.identifier == "details-done" }, "the details: \(Self.listing(layout))")
            let out = Self.outside(layout)
            #expect(out.isEmpty, "off the window's side: \(Self.listing(out))")
        }

        /// What is laid out past the window's left or right edge, but for
        /// what a scroll view holds beyond its own frame (a row of
        /// attachments or capsules scrolling sideways, as they are meant
        /// to): checked against that scroll view's frame instead.
        static func outside(_ layout: HeadlessLayout) -> [HeadlessLayout.Item] {
            let slack = 0.5
            var parents: [HeadlessLayout.Item] = []
            var out: [HeadlessLayout.Item] = []
            for item in layout.items {
                while let last = parents.last, last.depth >= item.depth || last.layer != item.layer { parents.removeLast() }
                defer { parents.append(item) }
                guard item.frame.width > 0, item.frame.height > 0 else { continue }
                if item.frame.minX < -slack || item.frame.maxX > layout.width + slack {
                    // Inside a scroll view that is itself within the
                    // window: its content scrolls, and is not cut off.
                    let scroll = parents.last { $0.kind == "scroll" }
                    if let scroll, scroll.frame.minX >= -slack, scroll.frame.maxX <= layout.width + slack,
                       scroll.frame.height < 120 { continue }
                    out.append(item)
                }
            }
            return out
        }

        static func listing(_ layout: HeadlessLayout) -> String { listing(layout.items) }

        static func listing(_ items: [HeadlessLayout.Item]) -> String {
            items.map { item in
                let f = item.frame
                return "\(String(repeating: " ", count: item.depth))\(item.kind) \"\(item.label.prefix(40))\" #\(item.identifier) L\(item.layer) x \(Int(f.minX))…\(Int(f.maxX)) y \(Int(f.minY)) h \(Int(f.height))"
            }.joined(separator: "\n")
        }
    }
}
