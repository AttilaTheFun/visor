// Signing in to a private registry before a container is made from an image
// in it (docs/co-tenancy.md, "Container images"): the image set in this
// server's settings, with a sign-in command beside it that prints the
// password (`aws ecr get-login-password` for ECR, good for 12 hours), run
// each time so a short-lived one is always fresh, and handed to the
// container host's `login` with the user set. Visor's own image, and any
// other with no sign-in set, are pulled as they are.

import Foundation
import VisorProtocol

extension VisorServer {
    /// The registry an image is in: its reference's first part where that
    /// names a host (a dot or a port in it, or `localhost`), else Docker
    /// Hub's.
    nonisolated static func registry(of image: String) -> String {
        let first = image.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        guard image.contains("/"), first.contains(".") || first.contains(":") || first == "localhost" else { return "docker.io" }
        return first
    }

    /// Signs the host in to `image`'s registry, when it is the image set
    /// and a sign-in is set with it; nothing otherwise.
    func signIn(for image: String, host: ContainerHost) async throws {
        let set = settings.containerImage.trimmingCharacters(in: .whitespaces)
        guard image == set, let program = settings.containerSignIn.first, !program.isEmpty else { return }
        let registry = Self.registry(of: image)
        let user = settings.containerSignInUser.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else {
            throw ContainerFailure(message: "Signing in to \(registry) needs a user as well as its sign-in (Settings → Containers).")
        }
        // By its name on the agents' PATH (`aws`), or as a path.
        guard let ran = await Command.output(ToolPath.resolve(program) ?? program, Array(settings.containerSignIn.dropFirst()),
                                             environment: ToolPath.environment(),
                                             errors: false, input: nil),
              ran.status == 0 else {
            throw ContainerFailure(message: "The sign-in for \(registry) (\(settings.containerSignIn.joined(separator: " "))) didn't give a password.")
        }
        let password = ran.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { throw ContainerFailure(message: "The sign-in for \(registry) printed no password.") }
        do {
            try await host.login(registry: registry, user: user, password: password)
        } catch let error as ContainerHostError {
            throw ContainerFailure(message: error.code == "unsupported"
                                   ? "The container host can't sign in to registries: update it, or use an image it can pull."
                                   : "Couldn't sign in to \(registry): \(error.message)")
        }
    }
}
