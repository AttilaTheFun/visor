import VisorProtocol

/// A relayed message this server has taken, from whichever client carried
/// it first: what became of it, so the same message carried again (by a
/// second client, or the first again after a lost answer) is answered the
/// same and not taken twice.
struct RelayLedgerEntry: Codable {
    var receipt: RelayReceipt
    /// When it was taken, in seconds since 1970.
    var at: Double
}
