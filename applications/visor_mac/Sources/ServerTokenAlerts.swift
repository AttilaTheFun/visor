// The admin token and the agents' tokens' signing keys, from the menu and
// Settings, over the server's API at its socket file (LocalServer), as the
// app's own calls: a token shown this once, with a Copy button; a reset or
// an emergency rotation asked first. The reset without the current token
// and the emergency rotation are taken from the app alone (its app key,
// MacAppKey). Thin on purpose: what they do is the server library's,
// tested on Linux.

import AppKit
import VisorClient

@MainActor
enum ServerTokenAlerts {
    /// Settings › Create Admin Token…: the first one, shown once. False
    /// when it wasn't made (there is one already).
    @discardableResult
    static func create(_ local: LocalServer) async -> Bool {
        do {
            showOnce(try await local.client.createAdminToken(), title: "Admin Token")
            await local.refresh()
            return true
        } catch {
            refused("The admin token wasn't made", error)
            return false
        }
    }

    /// The menu's Reset Admin Token…: a new one without the current one.
    static func reset(_ local: LocalServer) async {
        guard confirm("Reset the admin token?",
                      "A new admin token replaces the one there is, which stops working at once. The new one is shown once.",
                      button: "Reset") else { return }
        do {
            showOnce(try await local.client.resetAdminToken(), title: "New Admin Token")
            await local.refresh()
        } catch {
            refused("The admin token wasn't reset", error)
        }
    }

    /// The menu's Rotate Signing Keys and Emergency Key Rotation….
    static func rotateKeys(_ local: LocalServer, emergency: Bool) async {
        if emergency {
            guard confirm("Drop every signing key but a new one?",
                          "Every agent's token stops working at once: native sessions are given new ones, and runners' agents "
                            + "are restarted on new jobs. The admin token is unchanged.",
                          button: "Drop Them") else { return }
        }
        do {
            try await local.client.rotateSigningKeys(emergency: emergency)
        } catch {
            refused("The signing keys weren't rotated", error)
        }
    }

    private static func refused(_ title: String, _ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = VisorAgentServer.problem(error)
        alert.runModal()
    }

    private static func showOnce(_ token: String, title: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(token)\n\nShown this once: keep it where you keep secrets, and give it as VISOR_ADMIN_TOKEN."
        alert.addButton(withTitle: "Copy and Close")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            // Marked concealed (nspasteboard.org's convention), so clipboard
            // managers that honour it don't keep it. It is on the
            // pasteboard all the same, for any process of this user's to
            // read, until something else is copied.
            let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            NSPasteboard.general.clearContents()
            _ = NSPasteboard.general.declareTypes([.string, concealed], owner: nil)
            NSPasteboard.general.setString(token, forType: .string)
            NSPasteboard.general.setString("", forType: concealed)
        }
    }

    private static func confirm(_ title: String, _ text: String, button: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
