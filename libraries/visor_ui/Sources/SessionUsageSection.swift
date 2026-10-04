// What a chat has used — its context, its tokens, what they cost — and
// how near its agent's account is to its limits: a subscription's
// rolling windows, a key's budget, credits left.

import Foundation
import SwiftUI
import VisorProtocol

@MainActor
struct SessionUsageSection: View {
    let session: SessionInfo
    /// The agent's account, once a session of it has said.
    let account: AgentAccount?

    var body: some View {
        let now = Date().timeIntervalSince1970
        if session.contextUsed != nil || session.usage != nil {
            Section {
                if let used = session.contextUsed {
                    LabeledContent("Context", value: UsageWords.tokens(used) + (session.contextLimit.map { " of " + UsageWords.tokens($0) } ?? ""))
                }
                if let usage = session.usage {
                    LabeledContent("Tokens in", value: UsageWords.tokens(usage.input)
                        + (usage.input > 0 && usage.cached > 0 ? ", \(UsageWords.percent(Double(usage.cached) / Double(usage.input))) cached" : ""))
                    LabeledContent("Tokens out", value: UsageWords.tokens(usage.output))
                    if let cost = usage.cost {
                        LabeledContent(account?.subscription == true ? "At API prices" : "Cost", value: UsageWords.dollars(cost))
                    }
                }
            } header: {
                Text("Usage")
            } footer: {
                if account?.subscription == true, session.usage?.cost != nil {
                    Text("What these turns would cost at API prices; the subscription pays for them.")
                }
            }
        }
        if let account, account.plan != nil || !account.limits.isEmpty {
            Section {
                ForEach(account.limits, id: \.name) { UsageLimitRow(limit: $0, now: now) }
                if account.limits.isEmpty {
                    Text(account.subscription ? "No limits reported yet." : "Paid by the token, with no limit reported.")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text([session.agent.title, account.plan].compactMap { $0 }.joined(separator: " · "))
            } footer: {
                Text("As \(session.agent.title) last reported, \(UsageWords.ago(now - account.updated)).")
            }
        }
    }
}
