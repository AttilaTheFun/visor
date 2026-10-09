import SwiftUI
import VisorClient

/// The app's account's sign-in (`VisorAccount`), shown in place of the
/// computers while no one is signed in: one button, the account's own
/// sign-in behind it, and what went wrong if it did not happen.
@MainActor
struct AccountSignInView: View {
    @Environment(VisorStore.self) private var store
    let account: any VisorAccount
    @State private var signingIn = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Sign in to Visor").font(.title2.bold())
            Text("Your computers appear once you're signed in.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if signingIn {
                ProgressView()
            } else {
                Button("Sign In with \(account.title)") {
                    signingIn = true
                    failure = nil
                    Task {
                        failure = await store.signInAccount()
                        signingIn = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("account-sign-in")
            }
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
