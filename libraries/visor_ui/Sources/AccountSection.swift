import SwiftUI
import VisorClient

/// The sidebar's account section, where the app has an account: who is
/// signed in, by what, and Sign Out (which takes its computers away).
@MainActor
struct AccountSection: View {
    @Environment(VisorStore.self) private var store
    let account: any VisorAccount

    var body: some View {
        Section {
            Button(role: .destructive) { store.signOutAccount() } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right").rowLabel()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("account-sign-out")
        } header: {
            Text("Signed in with \(account.title)").noHeaderCase()
        }
    }
}
