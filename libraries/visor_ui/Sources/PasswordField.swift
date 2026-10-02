import AgentUI
import SwiftUI

/// A password field: SecureField where there is one, a plain field elsewhere.
struct PasswordField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        #if canImport(UIKit) || canImport(AppKit)
        SecureField(title, text: $text)
        #else
        TextField(title, text: $text)
        #endif
    }
}
