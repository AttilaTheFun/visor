// An agent's running total of a session's usage, taken apart: what it
// added since the last report, or — when the agent started counting over
// (launched again without what it had counted) — the whole of it.

import VisorProtocol

extension SessionUsage {
    /// Whether this running total carried on from `earlier` rather than
    /// starting over: nothing in it is less.
    func continues(from earlier: SessionUsage) -> Bool {
        input >= earlier.input && cached >= earlier.cached && output >= earlier.output && (cost ?? 0) >= (earlier.cost ?? 0)
    }

    /// What was used between `earlier` and this.
    func since(_ earlier: SessionUsage) -> SessionUsage {
        SessionUsage(input: input - earlier.input, cached: cached - earlier.cached, output: output - earlier.output,
                     cost: cost.map { $0 - (earlier.cost ?? 0) })
    }

    /// This and `more` together. A cost is kept once either has one.
    func adding(_ more: SessionUsage) -> SessionUsage {
        let cost: Double? = (self.cost == nil && more.cost == nil) ? nil : (self.cost ?? 0) + (more.cost ?? 0)
        return SessionUsage(input: input + more.input, cached: cached + more.cached, output: output + more.output, cost: cost)
    }
}
