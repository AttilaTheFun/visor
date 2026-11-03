/// Why a session could not be offered for a move, backed up or restored:
/// said to the user as it is.
struct MigrationFailure: Error, Sendable {
    let message: String
}
