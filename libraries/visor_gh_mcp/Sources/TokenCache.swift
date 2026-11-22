import Foundation

/// Tokens kept between calls, one an agent and owner. agent-token prints
/// no expiry, but hands out only tokens with more than five minutes left
/// and keeps each until then; so one kept here for at most `maxAge` (four
/// minutes) always has a minute left, and asking again costs agent-token a
/// file read until its token nears its end. A token GitHub refuses (401) is
/// dropped and asked for again.
public actor TokenCache {
    struct Kept {
        let token: String
        let fetched: Date
    }

    private let source: any TokenSource
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private var kept: [String: Kept] = [:]
    private var pending: [String: Task<String, Error>] = [:]

    public init(source: any TokenSource, maxAge: TimeInterval = 240, now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.maxAge = maxAge
        self.now = now
    }

    public func token(agent: String, owner: String) async throws -> String {
        let key = agent + "\u{0}" + owner.lowercased()
        if let kept = kept[key], now().timeIntervalSince(kept.fetched) < maxAge {
            return kept.token
        }
        if let task = pending[key] {
            return try await task.value
        }
        let source = self.source
        let task = Task { try await source.token(agent: agent, owner: owner) }
        pending[key] = task
        defer { pending[key] = nil }
        let token = try await task.value
        kept[key] = Kept(token: token, fetched: now())
        return token
    }

    /// `token` refused: the next call asks for another.
    public func invalidate(agent: String, owner: String, token: String) {
        let key = agent + "\u{0}" + owner.lowercased()
        if kept[key]?.token == token { kept[key] = nil }
    }
}
