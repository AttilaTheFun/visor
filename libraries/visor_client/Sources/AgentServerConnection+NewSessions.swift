import VisorProtocol
import VisorServices

// Starting a session, as the server sets them up: in a folder, or from its
// own choices; with its first message, where it starts only with one. And
// for a server that keeps no titles, archive or ending of its own, those
// kept on this device.

public extension AgentServerConnection {
    /// How a new session is set up on this server.
    var starting: SessionStarting { server.starting }

    /// Starts a session and returns its id once the server has it,
    /// subscribed; what went wrong is thrown, for whoever asked to show
    /// (the compose sheet keeps it, rather than opening a session that is
    /// not there). With `firstMessage`, for a server whose sessions start
    /// only with one, the session starts with it, and its id is the one
    /// the server gave.
    @discardableResult
    func start(id: String = AgentServerRecord.newID(), agent: AgentKind, cwd: String, title: String,
               skipPermissions: Bool, resume: String? = nil, firstMessage: String? = nil) async throws -> String {
        if let firstMessage {
            let started = try await server.startSession(id: id, agent: agent, cwd: cwd, title: title, skipPermissions: skipPermissions,
                                                        firstMessage: firstMessage)
            take([started], replacing: false)
            subscribe(started.id)
            return started.id
        }
        let list = try await server.startSession(id: id, agent: agent, cwd: cwd, title: title, skipPermissions: skipPermissions,
                                                 resume: resume)
        transcript(for: id).loaded = true
        take(list, replacing: false)
        subscribe(id)
        return id
    }

    /// Starts a Claude Code session in the computer's Sessions container
    /// (docs/containers.md, "Placing sessions"), in a folder of its own
    /// there, and returns its id once its agent has started, subscribed.
    /// The server's refusal is thrown in its words, for the compose sheet
    /// to show. Offered while `takesContainerSessions`.
    @discardableResult
    func startInContainer(title: String, model: String?, effort: String?, firstMessage: String? = nil) async throws -> String {
        let started = try await server.startSessionInContainer(title: title, model: model, effort: effort, text: firstMessage)
        take([started], replacing: false)
        subscribe(started.id)
        await refreshContainer()
        return started.id
    }

    /// Asks the server for the choices a new session starts from; what
    /// was had is kept when it does not answer.
    func loadStartChoices() async {
        guard let choices = try? await server.startChoices() else { return }
        startChoices = choices
    }
}

extension AgentServerConnection {
    /// Where this record's local edits are kept.
    private var localEditsKey: String { "sessionEdits." + id }

    func loadLocalEdits() -> LocalSessionEdits {
        let saved = VisorHost.settings?.get(key: localEditsKey) ?? ""
        return parseJSON(saved).map(LocalSessionEdits.init(json:)) ?? LocalSessionEdits()
    }

    /// Changes what is kept here, saves it, and lays it over the list.
    func editLocally(_ change: (inout LocalSessionEdits) -> Void) {
        guard var edits = localEdits else { return }
        change(&edits)
        localEdits = edits
        if !VisorFixture.active { VisorHost.settings?.set(key: localEditsKey, value: edits.json.encoded()) }
        sessions = edits.apply(to: sessions)
    }
}
