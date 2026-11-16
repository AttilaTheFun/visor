// The admin token and the agents' tokens' signing keys, from the menu and
// Settings (in this process: VisorServer's own calls, never REST): a token
// shown this once, with a Copy button; a reset or an emergency rotation
// asked first. Thin on purpose: what they do is the server library's,
// tested on Linux.

import AppKit
import VisorServer

@MainActor
enum TokenAlerts {
    /// Settings › Create Admin Token…: the first one, shown once. False
    /// when there is one already.
    @discardableResult
    static func create(_ server: VisorServer) -> Bool {
        guard let token = server.createAdminToken() else { return false }
        showOnce(token, title: "Admin Token")
        return true
    }

    /// The menu's Reset Admin Token…: a new one without the current one.
    static func reset(_ server: VisorServer) {
        guard confirm("Reset the admin token?",
                      "A new admin token replaces the one there is, which stops working at once. The new one is shown once.",
                      button: "Reset"),
              let token = server.resetAdminToken() else { return }
        showOnce(token, title: "New Admin Token")
    }

    /// The menu's Rotate Signing Keys and Emergency Key Rotation….
    static func rotateKeys(_ server: VisorServer, emergency: Bool) {
        if emergency {
            guard confirm("Drop every signing key but a new one?",
                          "Every agent's token stops working at once: native sessions are given new ones, and runners' agents "
                            + "are restarted on new jobs. The admin token is unchanged.",
                          button: "Drop Them") else { return }
        }
        guard server.rotateSigningKeys(dropPrevious: emergency) else {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "The signing keys weren't rotated"
            alert.informativeText = "The kept keys can't be read (Visor Server's log says why), and aren't written over. "
                + "Emergency Key Rotation… replaces them."
            alert.runModal()
            return
        }
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
