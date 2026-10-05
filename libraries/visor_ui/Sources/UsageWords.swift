// Amounts and times for the usage section, assembled by hand rather than
// with Foundation's formatters, which the lightweight Foundation on wasm
// and Android does not have.

import Foundation
import VisorProtocol

enum UsageWords {
    /// 850, 48k, 1.2M, 3.3B.
    static func tokens(_ count: Int64) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<100_000: return tenths(Double(count) / 1_000) + "k"
        case ..<1_000_000: return "\(count / 1_000)k"
        case ..<1_000_000_000: return tenths(Double(count) / 1_000_000) + "M"
        default: return tenths(Double(count) / 1_000_000_000) + "B"
        }
    }

    /// $4.12; under a cent, "<$0.01"; whole dollars without cents ($10).
    static func dollars(_ amount: Double) -> String {
        if amount > 0, amount < 0.005 { return "<$0.01" }
        let cents = Int64(whole: (amount * 100).rounded())
        let whole = grouped(cents / 100)
        return cents % 100 == 0 ? "$" + whole : "$\(whole).\(cents % 100 < 10 ? "0" : "")\(cents % 100)"
    }

    /// 62,500.
    static func grouped(_ number: Int64) -> String {
        let digits = String(number.magnitude)
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return (number < 0 ? "-" : "") + out
    }

    /// 22%.
    static func percent(_ share: Double) -> String { "\(Int64(whole: (share * 100).rounded()))%" }

    /// How long until a time: "40 min", "2 hr 10 min", "3 days 4 hr".
    static func duration(_ seconds: Double) -> String {
        let minutes = max(1, Int64(whole: seconds) / 60)
        let days = minutes / 1_440
        let hours = minutes % 1_440 / 60
        let rest = minutes % 60
        if days > 0 { return hours > 0 ? "\(days) day\(days == 1 ? "" : "s") \(hours) hr" : "\(days) day\(days == 1 ? "" : "s")" }
        if hours > 0 { return rest > 0 ? "\(hours) hr \(rest) min" : "\(hours) hr" }
        return "\(rest) min"
    }

    /// How long ago: "just now", "5 min ago", "2 hr ago", "3 days ago".
    static func ago(_ seconds: Double) -> String {
        seconds < 60 ? "just now" : duration(seconds).split(separator: " ").prefix(2).joined(separator: " ") + " ago"
    }

    private static func tenths(_ value: Double) -> String {
        let tenths = Int64(whole: (value * 10).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
    }
}
