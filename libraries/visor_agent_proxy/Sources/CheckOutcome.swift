/// What a check found (GateChecker): the write goes on, as it is or with a
/// field the proxy sets; it is refused, in gh_mcp's words; or GitHub didn't
/// answer what the check needed (a failure, not a refusal). An Error, so a
/// step that fails can be the answer of a Result.
enum CheckOutcome: Error, Equatable, Sendable {
    case pass(Rewrite?)
    case refuse(String)
    case fail(String)

    /// A field the proxy sets in the request before it goes on.
    enum Rewrite: Equatable, Sendable {
        /// A REST body's field, set only where the request left it out
        /// (a draft's `tag_name`, [RL7]).
        case bodyFieldIfAbsent(String, GateJSON)
        /// A field of the GraphQL input held by a variable (`expectedHeadOid`
        /// in `$input`, for gh pr merge).
        case variableField(variable: String, field: String, value: GateJSON)
    }
}
