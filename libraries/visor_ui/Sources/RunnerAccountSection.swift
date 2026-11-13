import SwiftUI
import VisorClient

/// A Runner's section in Settings: who is signed in to it, Sign Out (which
/// takes its computers away) or Sign In again, and Remove, which forgets it.
@MainActor
struct RunnerAccountSection: View {
    @Environment(VisorStore.self) private var store
    let account: RunnerAccount
    @State private var signingIn = false

    var body: some View {
        Section {
            if account.isSignedIn {
                Button { store.signOut(of: account) } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right").rowLabel()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("runner-sign-out")
            } else {
                Button { signingIn = true } label: {
                    Label("Sign In…", systemImage: "person.crop.circle.badge.checkmark").rowLabel()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("runner-sign-in-again")
            }
            Button(role: .destructive) { store.remove(account) } label: {
                Label("Remove MultiPass", systemImage: "trash").rowLabel()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("runner-remove")
        } header: {
            Text(account.isSignedIn ? account.title : account.title + ", signed out").noHeaderCase()
        }
        .sheet(isPresented: $signingIn) {
            NavigationStack {
                RunnerSignInForm(again: account) { signingIn = false }
                    .navigationTitle("Sign In")
                    .toolbarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { signingIn = false } }
                    }
            }
        }
    }
}
