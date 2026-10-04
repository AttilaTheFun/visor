// What Codex says of its account's limits: a ChatGPT plan's rolling
// windows and its credits. Updates are sparse — a field left out is not
// cleared, only not said — so each is laid over what was said before.

import Foundation
import VisorProtocol

extension CodexOutput {
    struct RateLimits: Sendable, Equatable {
        struct Window: Sendable, Equatable {
            let usedPercent: Double
            let minutes: Int?
            let resetsAt: Double?
        }

        var primary: Window?
        var secondary: Window?
        /// The credits left, unless they are unlimited.
        var credits: Double?

        init(_ snapshot: [String: Any]) {
            func window(_ value: Any?) -> Window? {
                guard let object = value as? [String: Any], let used = object["usedPercent"] as? Double else { return nil }
                return Window(usedPercent: used, minutes: object["windowDurationMins"] as? Int, resetsAt: object["resetsAt"] as? Double)
            }
            primary = window(snapshot["primary"])
            secondary = window(snapshot["secondary"])
            if let credits = snapshot["credits"] as? [String: Any], credits["unlimited"] as? Bool != true {
                self.credits = (credits["balance"] as? String).flatMap(Double.init) ?? credits["balance"] as? Double
            }
        }

        /// This update laid over what was said before.
        func merged(over earlier: RateLimits?) -> RateLimits {
            var merged = self
            merged.primary = primary ?? earlier?.primary
            merged.secondary = secondary ?? earlier?.secondary
            merged.credits = credits ?? earlier?.credits
            return merged
        }

        var limits: [UsageLimit] {
            var limits = [primary, secondary].compactMap { $0 }.map { window in
                UsageLimit(name: Self.name(minutes: window.minutes), used: window.usedPercent / 100, resets: window.resetsAt)
            }
            if let credits { limits.append(UsageLimit(name: "Credits", left: credits, unit: .credits)) }
            return limits
        }

        /// A window by its length: 300 minutes "5-hour", a week "Weekly".
        static func name(minutes: Int?) -> String {
            guard let minutes, minutes > 0 else { return "Limit" }
            switch minutes {
            case 10_080: return "Weekly"
            case 1_440: return "Daily"
            case let m where m % 1_440 == 0: return "\(m / 1_440)-day"
            case let m where m % 60 == 0: return "\(m / 60)-hour"
            default: return "\(minutes)-minute"
            }
        }
    }

    /// A ChatGPT plan by its id: "pro" → "ChatGPT Pro".
    static func planName(_ type: String) -> String {
        let words = type.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return "ChatGPT " + words
    }
}
