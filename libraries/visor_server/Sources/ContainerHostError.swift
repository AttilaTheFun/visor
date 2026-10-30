/// What a container host said went wrong (docs/container-host.md): its
/// words, and its code where it gave one (`busy`, `noImage`, `notFound`,
/// `unsupported`, `network`).
struct ContainerHostError: Error, Equatable, CustomStringConvertible {
    var message: String
    var code: String?

    var description: String { message }
}
