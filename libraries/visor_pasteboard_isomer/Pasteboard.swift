// Visor's pasteboard (visor's --//:pasteboard, module VisorPasteboard)
// on Isomer: the Isomer module's Clipboard, which the host answers (the
// browser's clipboard, Android's ClipboardManager, UIPasteboard under a
// compiled Isomer app's host).

import Isomer

public enum Pasteboard {
    @MainActor public static var string: String? {
        get { Clipboard.string }
        set { Clipboard.string = newValue }
    }
}
