// The slash commands a session's agent takes, for the composer to offer
// when the user types "/". Claude lists them (with what each does) each
// time it starts; a session that has not run since this server started
// is offered what the same agent listed last — kept on disk, so that is
// there from the first launch after any run.

import Foundation
import VisorProtocol

extension VisorServer {
    /// What a session's agent takes: its own list, the agent's last, or
    /// what its harness says it takes.
    func commands(for record: SessionRecord) -> [SlashCommand] {
        let agents = agentCommands(for: record)
        // Signing Claude Code in again is Visor's (`/login`), beside them.
        guard record.info.agent == .claude, !agents.contains(where: { $0.name == Self.signInCommand.name }) else { return agents }
        return agents + [Self.signInCommand]
    }

    private func agentCommands(for record: SessionRecord) -> [SlashCommand] {
        if !record.commands.isEmpty { return record.commands }
        if knownCommands.isEmpty { knownCommands = Self.keptCommands() }
        if let known = knownCommands[record.info.agent], !known.isEmpty { return known }
        return harnesses.harness(for: record.info.agent)?.commands ?? []
    }

    /// An agent listed its commands: the latest for that agent, kept.
    func keepCommands(_ list: [SlashCommand], for agent: AgentKind) {
        guard !list.isEmpty, knownCommands[agent] != list else { return }
        if knownCommands.isEmpty { knownCommands = Self.keptCommands() }
        knownCommands[agent] = list
        let byAgent = Dictionary(uniqueKeysWithValues: knownCommands.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(byAgent) { try? data.write(to: Self.commandsURL, options: .atomic) }
    }

    static func keptCommands() -> [AgentKind: [SlashCommand]] {
        guard let data = try? Data(contentsOf: commandsURL),
              let byAgent = try? JSONDecoder().decode([String: [SlashCommand]].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: byAgent.compactMap { key, value in AgentKind(rawValue: key).map { ($0, value) } })
    }
}
