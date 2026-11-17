// What a session tells the person of, by push from its server or by a
// client's own notification: the same rules on both sides.

extension SessionInfo {
    /// Whether an approval or a question it waits on is told: always,
    /// whatever its turn came from, unless its notifications are off.
    public var tellsApprovals: Bool { notifications }

    /// Whether the end of its latest turn is told (finished, failed, a
    /// goal achieved): not when its notifications are off, nor for a turn
    /// of mail (`TurnOrigin.mail`), its agent's reply in it included.
    public var tellsTurnEnd: Bool { notifications && turnOrigin != .mail }
}
