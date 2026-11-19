// The computer's own resolvers, as /etc/resolv.conf names them (macOS keeps
// it current with the network's, Tailscale's MagicDNS included when it is
// on), less the agent proxy's own addresses: asking itself would go round.

import Foundation

/// The resolvers the computer itself uses.
public enum SystemResolvers {
    /// The `nameserver` lines of `text` (resolv.conf's format), in order,
    /// with an IPv6 address's zone (`%en0`) dropped, and none of `excluding`.
    public static func parse(_ text: String, excluding: Set<String> = []) -> [DNSUpstream] {
        var found: [DNSUpstream] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count >= 2, words[0] == "nameserver", !words[0].hasPrefix("#") else { continue }
            let address = String(words[1].split(separator: "%", maxSplits: 1)[0])
            guard !address.isEmpty, !excluding.contains(address) else { continue }
            let upstream = DNSUpstream(address)
            if !found.contains(upstream) { found.append(upstream) }
        }
        return found
    }

    /// /etc/resolv.conf's, or none when it can't be read.
    public static func current(excluding: Set<String> = [], path: String = "/etc/resolv.conf") -> [DNSUpstream] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parse(text, excluding: excluding)
    }
}
