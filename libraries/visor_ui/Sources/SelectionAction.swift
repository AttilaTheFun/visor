import Observation

/// Opens something in the window (a session's fork, its side questions): a
/// callback held across a view's passes, as AgentUI's ViewAction is, so a
/// view given it compares by identity rather than never comparing equal.
@MainActor
@Observable
final class SelectionAction {
    @ObservationIgnored var run: (ContentSelection) -> Void

    init(run: @escaping (ContentSelection) -> Void = { _ in }) { self.run = run }

    func callAsFunction(_ selection: ContentSelection) { run(selection) }
}
