// The code Claude's sign-in page shows once the user has signed in
// (`<code>#<state>`), asked for when they come back to Visor from the page
// (View+SignInToClaude): typed or pasted, then sent to the sign-in.

import SwiftUI
import VisorPasteboard

@MainActor
struct SignInCodeSheet: View {
    /// Sends the code, as it is: the caller's way to the sign-in.
    let send: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Paste the code Claude showed after you signed in.")
                    TextField("Code from the sign-in page", text: $code)
                        .autocorrectionDisabled()
                        // No capitals put in for the user: the code is
                        // taken letter for letter.
                        .keyboardTypeURL()
                        .accessibilityIdentifier("sign-in-code")
                    // Read only when tapped: a phone asks before an app
                    // reads the pasteboard.
                    Button("Paste") {
                        if let pasted = Pasteboard.string { code = pasted.trimmed }
                    }
                    .accessibilityIdentifier("sign-in-paste")
                }
            }
            .insetGroupedForm()
            .navigationTitle("Sign-In Code")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("sign-in-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        send(code.trimmed)
                        dismiss()
                    }
                    .disabled(code.trimmed.isEmpty)
                    .accessibilityIdentifier("sign-in-send")
                }
            }
        }
        .presentationDetentsMediumLarge()
    }
}
