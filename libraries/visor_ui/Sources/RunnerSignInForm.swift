import SwiftUI
import VisorClient

/// Signing in to a Visor Runner (docs/runner-accounts.md): where it is, the
/// name and the password set on it (`visor-runner-agent user set`). Signed
/// in, its computers come into the sidebar, and `done` is called. Signing
/// in to one kept and signed out of, its address and name are fixed.
@MainActor
struct RunnerSignInForm: View {
    @Environment(VisorStore.self) private var store
    @State private var url: String
    @State private var username: String
    @State private var password = ""
    @State private var signingIn = false
    @State private var failure: String?
    /// The account signed in to again, or nil for a new one.
    private let again: RunnerAccount?
    let done: () -> Void

    init(again: RunnerAccount? = nil, done: @escaping () -> Void) {
        self.again = again
        self.done = done
        _url = State(initialValue: again?.url ?? "")
        _username = State(initialValue: again?.username ?? "")
    }

    private var ready: Bool { !url.trimmed.isEmpty && !username.trimmed.isEmpty && !password.isEmpty && !signingIn }

    var body: some View {
        Form {
            Section {
                if let again {
                    LabeledContent("Runner", value: again.url)
                    LabeledContent("Name", value: again.username)
                } else {
                    TitledField(title: "Runner") {
                        TextField("mini.example.ts.net:7445", text: $url)
                            .autocorrectionDisabled()
                            .keyboardTypeURL()
                            .accessibilityIdentifier("runner-url")
                    }
                    TitledField(title: "Name") {
                        TextField("Name", text: $username)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("runner-username")
                    }
                }
                TitledField(title: "Password") {
                    PasswordField("Password", text: $password)
                        .accessibilityIdentifier("runner-password")
                }
            } header: {
                Text("Visor Runner")
            } footer: {
                Text("A Runner on a Mac serves its computers to you: the Mac's own and its containers. Its name and password are the ones set on the Runner, with visor-runner-agent user set.")
            }
            Section {
                if signingIn {
                    ProgressView()
                } else {
                    Button("Sign In", action: submit)
                        .disabled(!ready)
                        .accessibilityIdentifier("runner-sign-in")
                }
                if let failure {
                    Text(failure).font(.footnote).foregroundColor(.red)
                }
            }
        }
        .insetGroupedForm()
        .onSubmit(submit)
    }

    private func submit() {
        guard ready else { return }
        signingIn = true
        failure = nil
        Task {
            failure = await store.signInToRunner(url: url.trimmed, username: username.trimmed, password: password)
            signingIn = false
            if failure == nil { done() }
        }
    }
}
