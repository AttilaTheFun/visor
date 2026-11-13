import Foundation
import SwiftUI
import VisorClient

/// Signing in to a MultiPass (MultiPass's docs/front-door.md), three ways:
/// its pairing code (`multipass-agent pair`, on its computer), GitHub
/// (MultiPass asks GitHub; the person enters a code at GitHub's page), or a
/// name and password (`multipass-agent user set`). Signed in, its Visor
/// servers come into the sidebar, and `done` is called. Signing in to one
/// kept and signed out of, its address is fixed.
@MainActor
struct RunnerSignInForm: View {
    @Environment(VisorStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var code = ""
    @State private var url: String
    @State private var username: String
    @State private var password = ""
    @State private var signingIn = false
    @State private var github: RunnerAccount.GitHubSignIn?
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

    private var hasURL: Bool { !url.trimmed.isEmpty }

    var body: some View {
        Form {
            if again == nil {
                Section {
                    TitledField(title: "Pairing code") {
                        TextField("multipass1:…", text: $code)
                            .autocorrectionDisabled()
                            .keyboardTypeURL()
                            .accessibilityIdentifier("multipass-code")
                    }
                    Button("Sign In with the Code", action: pair)
                        .disabled(!MultiPassCode.isOne(code) || signingIn)
                        .accessibilityIdentifier("multipass-pair")
                } header: {
                    Text("MultiPass")
                } footer: {
                    Text("A MultiPass serves a computer's Visor servers to you. Its pairing code comes from multipass-agent pair on that computer, and is good once, for ten minutes.")
                }
            }
            Section {
                if let again {
                    LabeledContent("MultiPass", value: again.url)
                } else {
                    TitledField(title: "Address") {
                        TextField("mini.example.ts.net:7443", text: $url)
                            .autocorrectionDisabled()
                            .keyboardTypeURL()
                            .accessibilityIdentifier("runner-url")
                    }
                }
                if let github {
                    LabeledContent("Code", value: github.userCode)
                        .accessibilityIdentifier("github-code")
                    Button("Open GitHub") { if let page = URL(string: github.verificationURI) { openURL(page) } }
                    HStack {
                        ProgressView()
                        Text("Waiting for GitHub…").foregroundStyle(.secondary)
                    }
                } else {
                    Button("Sign In with GitHub", action: signInWithGitHub)
                        .disabled(!hasURL || signingIn)
                        .accessibilityIdentifier("github-sign-in")
                }
            } header: {
                Text("GitHub")
            } footer: {
                Text("Enter the code at GitHub's page. Only the GitHub accounts this MultiPass lets in can sign in.")
            }
            Section {
                if again == nil {
                    TitledField(title: "Name") {
                        TextField("Name", text: $username)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("runner-username")
                    }
                } else {
                    LabeledContent("Name", value: username)
                }
                TitledField(title: "Password") {
                    PasswordField("Password", text: $password)
                        .accessibilityIdentifier("runner-password")
                }
                Button("Sign In", action: submit)
                    .disabled(!hasURL || username.trimmed.isEmpty || password.isEmpty || signingIn)
                    .accessibilityIdentifier("runner-sign-in")
            } header: {
                Text("Name and Password")
            } footer: {
                Text("The ones set on the MultiPass, with multipass-agent user set.")
            }
            if signingIn && github == nil || failure != nil {
                Section {
                    if signingIn && github == nil { ProgressView() }
                    if let failure {
                        Text(failure).font(.footnote).foregroundColor(.red)
                    }
                }
            }
        }
        .insetGroupedForm()
        .onSubmit(submit)
    }

    private func pair() {
        begin {
            await store.signInToMultiPass(code: code)
        }
    }

    private func submit() {
        guard hasURL, !username.trimmed.isEmpty, !password.isEmpty else { return }
        begin {
            await store.signInToRunner(url: url.trimmed, username: username.trimmed, password: password)
        }
    }

    /// GitHub's sign-in: begun with MultiPass, shown, then asked after at
    /// GitHub's pace until the person has signed in there or can't.
    private func signInWithGitHub() {
        let account = again ?? store.multiPassAccount(url: url.trimmed)
        begin {
            do {
                let started = try await account.startGitHubSignIn()
                github = started
                defer { github = nil }
                while true {
                    try await Task.sleep(for: .seconds(started.interval))
                    if try await account.finishGitHubSignIn(started) { break }
                }
                store.addSignedIn(account)
                return nil
            } catch {
                return "\(error)"
            }
        }
    }

    /// A sign-in under way: its failure shown, or `done` once it worked.
    private func begin(_ work: @escaping @MainActor () async -> String?) {
        signingIn = true
        failure = nil
        Task {
            failure = await work()
            signingIn = false
            if failure == nil { done() }
        }
    }
}
