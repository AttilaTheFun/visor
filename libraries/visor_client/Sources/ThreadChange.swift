/// What a sync did to the rows a thread shows, for the connection log, when
/// it was more than rows added at the end or changed in place: an answer
/// taken whole, rows that went or came in another place, rows shown twice.
/// Those are what make a list lay its rows out again and can lose its place
/// on screen; the log says which happened, and when, next to the app
/// coming back and its channels opening.
struct ThreadChange: CustomStringConvertible {
    let whole: Bool
    let generation: (before: Int, after: Int)
    let revision: (before: Int, after: Int)
    let count: (before: Int, after: Int)
    /// Rows shown before that are no longer, by the ids the thread shows.
    let went: Int
    /// Rows shown now that were not, other than those after the last one
    /// that was (rows added at the end).
    let cameInBetween: Int
    /// Ids shown more than once.
    let duplicates: Int

    /// Nil for a change of no note: rows added at the end, or changed in
    /// place, under ids that each appear once.
    init?(before: [String], after: [String], whole: Bool, generation: (Int, Int), revision: (Int, Int)) {
        let now = Set(after)
        let had = Set(before)
        went = before.filter { !now.contains($0) }.count
        // Rows added at the end are the ones past the last row that was
        // there before; anything new before that came in between.
        let lastKept = after.lastIndex { had.contains($0) } ?? -1
        cameInBetween = after.prefix(lastKept + 1).filter { !had.contains($0) }.count
        duplicates = after.count - now.count
        self.whole = whole
        self.generation = generation
        self.revision = revision
        count = (before.count, after.count)
        guard whole || went > 0 || cameInBetween > 0 || duplicates > 0 else { return nil }
    }

    var description: String {
        var parts = [whole ? "taken whole" : "a delta",
                     "revision \(revision.before) → \(revision.after)",
                     "rows \(count.before) → \(count.after)"]
        if generation.before != generation.after { parts.append("generation \(generation.before) → \(generation.after)") }
        if went > 0 { parts.append("\(went) went") }
        if cameInBetween > 0 { parts.append("\(cameInBetween) came in between") }
        if duplicates > 0 { parts.append("\(duplicates) shown twice") }
        return parts.joined(separator: ", ")
    }
}
