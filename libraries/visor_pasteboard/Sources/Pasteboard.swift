#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The system pasteboard's text: AppKit's on the Mac, UIKit's on an iPhone
/// or iPad, and none where there is neither (read as nil, written to
/// nowhere). A host with a clipboard of its own builds the client with its
/// own library of this module (`--@visor//:pasteboard`).
public enum Pasteboard {
    @MainActor public static var string: String? {
        get {
            #if canImport(AppKit)
            NSPasteboard.general.string(forType: .string)
            #elseif canImport(UIKit)
            UIPasteboard.general.string
            #else
            nil
            #endif
        }
        set {
            #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
            #elseif canImport(UIKit)
            UIPasteboard.general.string = newValue
            #endif
        }
    }
}
