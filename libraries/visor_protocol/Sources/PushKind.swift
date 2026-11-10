/// What a push, or a device's own notification, says happened in a
/// session: the kinds a device may mute (`push`'s `pushMuted`). A state
/// change pushed silently, for the widget, is none of them and always goes.
public enum PushKind: String, CaseIterable, Sendable {
    /// An agent waiting for approval or asking a question.
    case waiting
    /// An agent stopped by an error.
    case failed
    /// A goal achieved.
    case goal
    /// A turn finished.
    case turn

    /// What Settings calls it.
    public var title: String {
        switch self {
        case .waiting: "Waiting for you"
        case .failed: "Stopped with an error"
        case .goal: "Goal achieved"
        case .turn: "Turn finished"
        }
    }
}
