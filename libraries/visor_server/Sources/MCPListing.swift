// One session's last good list of one passed-on MCP endpoint's tools
// (MCPProxy): what it answered last, when it began failing since, and when
// it is to be asked again.

import Foundation
import VisorProtocol

struct MCPListing: Equatable {
    /// The endpoint's address when it was listed: a moved endpoint starts again.
    let url: String
    /// Its tools as it last listed them, renamed under it; nil until it has.
    private(set) var good: [JSONValue]?
    /// When it began failing, if it is failing.
    private(set) var failingSince: Date?
    /// How many times in a row it has failed.
    private(set) var failures = 0
    /// Not asked again before this (`distantPast`: ask now).
    private(set) var retryAt = Date.distantPast

    init(url: String) {
        self.url = url
    }

    /// It answered with `tools`.
    mutating func answered(_ tools: [JSONValue]) {
        good = tools
        failingSince = nil
        failures = 0
        retryAt = .distantPast
    }

    /// It didn't answer at `time`: asked again after 2 s, doubled after each
    /// failure in a row, up to `MCPProxy.listRetryLimit`.
    mutating func failed(at time: Date) {
        failingSince = failingSince ?? time
        failures += 1
        retryAt = time.addingTimeInterval(min(2 * pow(2, Double(min(failures - 1, 16))), MCPProxy.listRetryLimit))
    }

    /// Its tools to list at `time`: the last good ones, unless it has been
    /// failing for `MCPProxy.forgetAfter`.
    func tools(at time: Date) -> [JSONValue]? {
        if let failingSince, time.timeIntervalSince(failingSince) >= MCPProxy.forgetAfter { return nil }
        return good
    }
}
