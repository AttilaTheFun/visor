// The content at its narrowest, 320 points wide (Logan, 27 Nov 2026: the
// narrowest an iPad app gets in Stage Manager, and the Mac window's least):
// the chat with its composer, and the session's details from it, one column
// at a time as on a phone. Headless alone, where the window's width is the
// test's. (The headless layout's frames are not the drawn ones, so whether
// anything runs off the side is the Mac proof's to show: proof_mac.sh's
// chat-320 and inspector-320.)

import IsomerHeadless
import Testing

extension FeatureMapTests {
    @Suite("Narrowest width", .enabled(if: VisorLaunch.headless, "a headful device's width is its own"))
    struct NarrowestWidth {
        @Test("Session chat at 320 points → Session details: tap session-title, and back by details-done")
        func chat() throws {
            let app = try VisorLaunch.fixture("chat", width: .narrowest)
            defer { app.quit() }
            let chat = try app.screen(within: 15) { FeatureMapNode.chat.isShown(on: $0) }
            #expect(try app.layout().width == Double(VisorLaunch.Width.narrowest.size.width))
            // The composer, and the approval waiting in it.
            #expect(chat.elements.contains { $0.role == "textField" && $0.label.hasPrefix("Message Claude Code") }, "\(chat.summary)")
            #expect(chat.has(label: "Allow") && chat.has(label: "Deny"), "\(chat.summary)")
            FeatureMapNode.details.expectShown(on: try app.tap("session-title"))
            FeatureMapNode.chat.expectShown(on: try app.tap("details-done"))
        }

        @Test("Settings at 320 points: a computer's page and back")
        func settings() throws {
            let app = try VisorLaunch.fixture("sessions", width: .narrowest)
            defer { app.quit() }
            try app.screen(within: 15) { $0.has(id: "settings") }
            FeatureMapNode.settings.expectShown(on: try app.tap("settings"))
            FeatureMapNode.computer.expectShown(on: try app.tap("settings-computer-Snapshot Mac"))
        }
    }
}
