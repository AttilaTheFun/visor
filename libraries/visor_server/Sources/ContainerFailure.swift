/// Why a session's container could not be made, or its agent moved into
/// or out of one: said to the user as it is.
struct ContainerFailure: Error, Sendable {
    let message: String
}
