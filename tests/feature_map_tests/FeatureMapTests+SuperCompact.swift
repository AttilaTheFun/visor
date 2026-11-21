// Super Compact, from a session's menu: the sheet started, followed and
// cancelled; HANDOFF.md reviewed (the note on secrets above it), edited
// and saved, discarded, or started from; and, once carried on, the new
// session's chat with its "Continued from …" row, which leads back to the
// old one's "Continued as …". The fixture's computer fakes the job.

import IsomerHeadless
import Testing

extension FeatureMapTests {
    @Suite("Super Compact")
    struct SuperCompact {
        static func mentions(_ screen: HeadlessScreen, _ text: String) -> Bool {
            Archives.mentions(screen, text)
        }

        @Test("Sessions → Super Compact: longpress session-‹id›, tap “Super Compact…”")
        func opens() throws {
            let app = try VisorLaunch.fixture("sessions")
            defer { app.quit() }
            try app.screen { FeatureMapNode.sessions.isShown(on: $0) }
            let menu = try app.longPress("session-fixture-chat")
            #expect(menu.element("Super Compact…") != nil, "no Super Compact… in the menu: \(menu.summary)")
            try app.tap("Super Compact…")
            FeatureMapNode.superCompact.expectShown(on: try app.screen { FeatureMapNode.superCompact.isShown(on: $0) })
        }

        @Test("Super Compact → running: tap super-compact-start; → ready: tap super-compact-cancel")
        func startsAndCancels() throws {
            let app = try VisorLaunch.fixture("sessions")
            defer { app.quit() }
            try app.screen { FeatureMapNode.sessions.isShown(on: $0) }
            try app.longPress("session-fixture-chat")
            try app.tap("Super Compact…")
            try app.screen { FeatureMapNode.superCompact.isShown(on: $0) }
            try app.tap("super-compact-start")
            let running = try app.screen { FeatureMapNode.superCompactRunning.isShown(on: $0) }
            FeatureMapNode.superCompactRunning.expectShown(on: running)
            #expect(Self.mentions(running, "of 40"), "chunk n of N: \(running.summary)")
            try app.tap("super-compact-cancel")
            let ready = try app.screen { FeatureMapNode.superCompact.isShown(on: $0) && Self.mentions($0, "cancelled") }
            FeatureMapNode.superCompact.expectShown(on: ready)
            #expect(Self.mentions(ready, "The last one was cancelled."), "\(ready.summary)")
        }

        @Test("Super Compact running ⇢ review: the job runs to its end")
        func runsToReview() throws {
            let app = try VisorLaunch.fixture("sessions")
            defer { app.quit() }
            try app.screen { FeatureMapNode.sessions.isShown(on: $0) }
            try app.longPress("session-fixture-chat")
            try app.tap("Super Compact…")
            try app.screen { FeatureMapNode.superCompact.isShown(on: $0) }
            try app.tap("super-compact-start")
            // Polled every two seconds, a few steps to its end.
            let review = try app.screen(within: 30) { FeatureMapNode.superCompactReview.isShown(on: $0) }
            FeatureMapNode.superCompactReview.expectShown(on: review)
            #expect(Self.mentions(review, "Handoff: Offline sync"), "\(review.summary)")
        }

        @Test("Super Compact review: the note on secrets, the check's warning and HANDOFF.md")
        func reviews() throws {
            let app = try VisorLaunch.fixture("super-compact-review")
            defer { app.quit() }
            let review = try app.screen { FeatureMapNode.superCompactReview.isShown(on: $0) && Self.mentions($0, "Handoff: Offline sync") }
            FeatureMapNode.superCompactReview.expectShown(on: review)
            #expect(review.has(id: "super-compact-secrets-note"), "\(review.summary)")
            #expect(Self.mentions(review, "It may include secrets that appeared in tool output"), "\(review.summary)")
            #expect(Self.mentions(review, "Keep the order rows were written in"), "the check's warning: \(review.summary)")
            #expect(Self.mentions(review, "Rules and decisions"), "\(review.summary)")
        }

        @Test("Super Compact review → Edit: tap super-compact-edit; type, tap super-compact-save")
        func edits() throws {
            let app = try VisorLaunch.fixture("super-compact-review")
            defer { app.quit() }
            try app.screen { FeatureMapNode.superCompactReview.isShown(on: $0) }
            try app.tap("super-compact-edit")
            FeatureMapNode.superCompactEdit.expectShown(on: try app.screen { FeatureMapNode.superCompactEdit.isShown(on: $0) })
            try app.type("super-compact-editor", "# Handoff: edited by hand")
            try app.tap("super-compact-save")
            let saved = try app.screen { FeatureMapNode.superCompactReview.isShown(on: $0) && Self.mentions($0, "edited by hand") }
            FeatureMapNode.superCompactReview.expectShown(on: saved)
            #expect(Self.mentions(saved, "Handoff: edited by hand"), "the edit drawn: \(saved.summary)")
        }

        @Test("Super Compact review → ready: tap super-compact-discard, “Discard”")
        func discards() throws {
            let app = try VisorLaunch.fixture("super-compact-review")
            defer { app.quit() }
            try app.screen { FeatureMapNode.superCompactReview.isShown(on: $0) }
            try app.tap("super-compact-discard")
            try app.screen { $0.element("Discard") != nil && Self.mentions($0, "Discard this handoff?") }
            try app.tap("Discard")
            let ready = try app.screen { FeatureMapNode.superCompact.isShown(on: $0) }
            FeatureMapNode.superCompact.expectShown(on: ready)
            #expect(Self.mentions(ready, "The last handoff was discarded."), "\(ready.summary)")
        }

        @Test("Super Compact review → done: tap super-compact-cutover; the new session opens")
        func cutsOver() throws {
            let app = try VisorLaunch.fixture("super-compact-review")
            defer { app.quit() }
            try app.screen { FeatureMapNode.superCompactReview.isShown(on: $0) }
            try app.tap("super-compact-cutover")
            let done = try app.screen { FeatureMapNode.superCompactDone.isShown(on: $0) }
            FeatureMapNode.superCompactDone.expectShown(on: done)
            #expect(Self.mentions(done, "Offline sync (continued)"), "\(done.summary)")
            try app.tap("super-compact-done")
            let chat = try app.screen { $0.has(id: "continued-from") }
            #expect(chat.has(id: "continued-from"), "the new session's chat: \(chat.summary)")
            #expect(Self.mentions(chat, "I've read HANDOFF.md in full"), "\(chat.summary)")
        }

        @Test("Super Compact done → Session chat: tap super-compact-open; continued-from ↔ continued-as")
        func linksBothWays() throws {
            let app = try VisorLaunch.fixture("super-compact-done")
            defer { app.quit() }
            try app.screen { FeatureMapNode.superCompactDone.isShown(on: $0) }
            try app.tap("super-compact-open")
            let next = try app.screen { $0.has(id: "continued-from") }
            #expect(Self.mentions(next, "Continued from “Offline sync”"), "\(next.summary)")
            try app.tap("continued-from")
            let old = try app.screen { $0.has(id: "continued-as") }
            #expect(Self.mentions(old, "Continued as “Offline sync (continued)”"), "the old session's chat: \(old.summary)")
            try app.tap("continued-as")
            #expect(try app.screen { $0.has(id: "continued-from") }.has(id: "continued-from"))
        }
    }
}
