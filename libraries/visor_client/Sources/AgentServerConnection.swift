// One agent server: its saved record, the live channel to it (through its
// provider's `AgentServer`, so a Visor server and a fork's service
// drive the same connection), the sessions it lists, and a transcript per
// session the UI observes. Reconnects with a short backoff while the app
// is open. No Combine: observation is SwiftUI's, waiting is async/await.

import MessageCache
import Observation
import SwiftUI
import VisorProtocol
import VisorServices

@MainActor
@Observable
public final class AgentServerConnection: Identifiable {
    public enum State: Equatable {
        case disconnected
        case connecting
        case connected
        /// Reached before, unreachable now (the socket dropped or never opened).
        case offline(String)
        /// The host answered and refused (a wrong password) or errs.
        case failed(String)
        /// The server does not know this device and wants the user to
        /// sign in (for a Mac: the password its menu bar app shows), or
        /// the credentials saved are wrong.
        case needsAuthentication

        public var label: String {
            switch self {
            case .disconnected: "Not connected"
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case .offline(let reason): "Offline: \(reason)"
            case .failed(let message): "Error: \(message)"
            case .needsAuthentication: "Needs signing in"
            }
        }

        public var wantsAuthentication: Bool { if case .needsAuthentication = self { true } else { false } }
    }

    /// The sidebar badge: green connected; yellow reachable before, not
    /// now; red never reached, or the last attempt answered with an error.
    public enum Badge { case connected, wasConnected, unreachable }
    public var badge: Badge {
        switch state {
        case .connected: return .connected
        case .failed, .needsAuthentication: return .unreachable
        default: return record.everConnected ? .wasConnected : .unreachable
        }
    }

    public var record: AgentServerRecord {
        didSet { onRecordChange?() }
    }
    public private(set) var state: State = .disconnected
    /// Whether the server is followed live over its channel, or by polling
    /// (where the path carries no WebSocket): the same, more slowly.
    public private(set) var live = true
    public internal(set) var sessions: [SessionInfo] = [] {
        // A server that keeps no titles or archive of its own: what the
        // user did here is laid over every list it sends.
        didSet {
            if let localEdits {
                let edited = localEdits.apply(to: sessions)
                if edited != sessions { sessions = edited }
            }
            // Each open session's own, for its chat (`SessionTranscript.info`).
            let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, transcript) in transcripts { transcript.info = byID[id] }
        }
    }
    /// The renames, archiving and removals kept on this device, for a
    /// server that keeps none (`AgentServer.managesSessions` false).
    var localEdits: LocalSessionEdits?
    /// The server's own choices a new session starts from, when it starts
    /// them so (`starting.fromChoices`): asked for on each connect.
    public internal(set) var startChoices: [StartChoice] = []
    /// Not observed: no view reads the dictionary, and its first write for
    /// a session happens while the screen that opens it is being built,
    /// which invalidated the screen's parent for one more pass.
    @ObservationIgnored public private(set) var transcripts: [String: SessionTranscript] = [:]
    /// Each provider's models, from the host.
    public internal(set) var catalogs: [AgentCatalog] = []
    /// The server can start a session whose agent runs in a container on
    /// its oss, rather than on the computer.
    public internal(set) var containersAvailable = false
    /// The Visor Server it runs, as it said at sign-in ("0.31 (8)").
    public private(set) var serverVersion: String?
    /// The store saves when the address or credentials change.
    @ObservationIgnored var onRecordChange: (() -> Void)?

    public nonisolated var id: String { recordID }
    private nonisolated let recordID: String
    /// Bumped whenever the live channel is closed, so a closed channel's
    /// late events are ignored.
    private var generation = 0
    /// The server itself, from its provider.
    let server: any AgentServer
    private var wantsConnection = false
    private var attempt = 0
    private var pendingSubscriptions: Set<String> = []
    /// The paths to the server for this round of tries, the one that
    /// answered last time first; `pathIndex` is the one being tried.
    private var paths: [String] = []
    private var pathIndex = 0
    /// The path the last sign-in answered on, kept in the record so a
    /// launch starts with it.
    private var lastGoodPath: String? {
        get { record.lastPath.isEmpty ? nil : record.lastPath }
        set { if record.lastPath != (newValue ?? "") { record.lastPath = newValue ?? "" } }
    }
    /// A channel that was up is being opened again, and the server is
    /// still shown as connected: it is taken to be until a try fails, or
    /// the new channel takes longer than `quietHold`.
    private var quiet = false
    /// Told when the server is connected and has said who it is (the
    /// store folds other records of it into this one, and the relay
    /// reports to it).
    @ObservationIgnored var onConnected: (() -> Void)?
    /// Told when the server has messages for this device to carry
    /// (RelayCourier).
    @ObservationIgnored var onRelay: (() -> Void)?
    /// The path the server was reached by, this time.
    public private(set) var path: String?
    /// This device's SSH key was handed to the server once this
    /// connection, so a refusal after that is not tried again.
    private var sshEnrolled = false

    public init(record: AgentServerRecord) {
        self.server = AgentServerProviders.server(for: record)
        self.record = record
        self.recordID = record.id
        if !server.managesSessions { localEdits = loadLocalEdits() }
        loadProjects()
        loadCachedSessions()
    }

    /// Told when the server sends a new list of its sessions (the store
    /// keeps the home screen's widget up to date by it).
    @ObservationIgnored var onSessionsChange: (() -> Void)?

    /// The last command that failed, for the UI.
    public var commandError: String?

    /// The server's subfolders of `path` (the picker); the resolved path comes back too.
    public func folders(at path: String) async throws -> (path: String, folders: [String]) {
        let listing = try await server.folders(at: path)
        return (listing.path, listing.folders)
    }

    /// Whether the folder is still on the server (a project whose folder
    /// was renamed or moved answers false).
    public func folderExists(_ path: String) async throws -> Bool {
        try await server.folders(at: path).exists
    }

    /// The bytes of a picture the server holds, base64.
    public func fileData(path: String) async throws -> String {
        try await server.fileData(path: path)
    }

    /// Puts a picture or a video on the server and returns where it landed, which
    /// is what the agent is then pointed at.
    public func upload(base64: String, name: String) async throws -> String {
        try await server.upload(base64: base64, name: name)
    }

    /// The messages on this server whose words match, across every
    /// session, best first.
    public func search(_ query: String) async throws -> [SearchHit] {
        try await server.search(query)
    }

    /// Gives the server this device's push token, so it can say when a
    /// turn ends or an agent waits, with the app closed. Again on each
    /// connect: the server keeps the latest.
    public func registerForPush() {
        let handler = VisorNotificationHandler.shared
        guard state == .connected, let token = handler.token else { return }
        let (platform, environment, topic) = (handler.platform, handler.environment, handler.topic)
        Task { [weak self] in
            // Whether the server sends pushes: then it says what happened,
            // and this device does not say it too.
            let pushes = try? await self?.server.registerPush(token: token, platform: platform, environment: environment, topic: topic)
            self?.serverPushes = pushes ?? false
        }
    }

    /// The server sends this device pushes: local notifications would say
    /// the same thing twice.
    var serverPushes = false

    /// Tells the user (where the host can) what changed in a session while
    /// they may not be looking: a turn finished, an agent waiting for
    /// approval, a goal done. Only for a change the server announced:
    /// the first list after connecting says what is, not what happened.
    func notifyChanges(from before: [SessionInfo], to after: [SessionInfo]) {
        guard let notifications = VisorHost.notifications, !serverPushes else { return }
        for new in after {
            guard let old = before.first(where: { $0.id == new.id }), !new.archived, !new.ended else { continue }
            // What the session said as its turn began: the user's message.
            if !old.busy, new.busy { turnPrompts[new.id] = new.preview ?? "" }
            let prompt = old.busy && !new.busy ? turnPrompts.removeValue(forKey: new.id) : nil
            let title = new.title.isEmpty ? new.agent.title : new.title
            // The server, the session and what it says: the id replaces an
            // older one, and says where to go when it is opened.
            let id = { (kind: String) in VisorNotificationID(computer: self.record.address, session: new.id, kind: kind).rawValue }
            if new.pendingApproval != nil, old.pendingApproval == nil, let approval = new.pendingApproval {
                if let question = approval.questions?.first {
                    notifications.notify(id: id("approval"), title: "\(title) asks", body: question.question)
                } else {
                    notifications.notify(id: id("approval"), title: "\(title) is waiting",
                                         body: "Allow \(approval.tool)? " + approval.summary)
                }
            }
            if let goal = old.goal, new.goal == nil {
                notifications.notify(id: id("goal"), title: "\(title): goal done", body: goal)
            } else if old.busy, !new.busy {
                notifications.notify(id: id("turn"), title: "\(title) finished", body: Self.finishedBody(new.preview, prompt: prompt))
            }
        }
    }

    /// What each session said as its turn began (the user's message), by
    /// session id, until the turn ends.
    private var turnPrompts: [String: String] = [:]

    /// What a "finished" notification says: the session's newest words,
    /// unless they are what it said as the turn began — the user's own
    /// message, the agent having said nothing since (or its row not read
    /// yet).
    static func finishedBody(_ preview: String?, prompt: String?) -> String {
        guard let preview, !preview.isEmpty, preview != prompt else { return "Ready for your reply" }
        return preview
    }

    /// The slash commands a session's agent takes, as the server knows
    /// them (none for an agent that lists none).
    public func commands(for sessionID: String) async throws -> [SlashCommand] {
        try await server.commands(for: sessionID)
    }

    /// The server's connection codes, as it shows them itself: what this
    /// device shows to add the server on another.
    public func connectionCodes() async throws -> ConnectionCodes {
        try await server.connectionCodes()
    }

    /// Whether the relay is there to take part in: the server has one, and
    /// does not stand alone.
    public var offersRelay: Bool { server.relays && !isolated }

    /// Whether this device takes part in the relay with this server: the
    /// record's choice, else the app's default.
    public var relayEnabled: Bool {
        offersRelay && (record.relay ?? RelayCourier.onByDefault)
    }

    /// Creates the folder (and its parents) on the server.
    public func makeFolder(_ path: String) async throws -> String {
        try await server.makeFolder(path)
    }

    /// The agent's own sessions started in `cwd`, newest first.
    public func resumable(agent: AgentKind, cwd: String) async throws -> [ResumableSession] {
        try await server.resumable(agent: agent, cwd: cwd)
    }

    /// One command on a session; the sessions the answer names refresh
    /// the list at once (the channel's broadcast follows for everyone
    /// else). After `.end` they replace it.
    private func act(_ action: SessionAction, on sessionID: String) {
        perform { [weak self] in
            let list = try await self?.server.act(action, on: sessionID) ?? []
            self?.take(list, replacing: action == .end)
        }
    }

    /// Runs one operation, keeping what went wrong for the UI.
    private func perform(_ operation: @escaping @MainActor () async throws -> Void, then: (() -> Void)? = nil) {
        Task { [weak self] in
            do {
                try await operation()
                guard let self else { return }
                self.commandError = nil
                then?()
            } catch {
                self?.commandError = "\(error)"
            }
        }
    }

    /// The sessions an answer named, into the list.
    func take(_ list: [SessionInfo], replacing: Bool) {
        if replacing {
            sessions = list
            return
        }
        for info in list {
            if let index = sessions.firstIndex(where: { $0.id == info.id }) { sessions[index] = info } else { sessions.append(info) }
        }
    }

    /// Edits the saved address or credentials (the store saves through `onRecordChange`).
    public func update(_ change: (inout AgentServerRecord) -> Void) {
        var next = record
        change(&next)
        record = next
    }

    public func connect() {
        note("connect asked for")
        wantsConnection = true
        attempt = 0
        pathIndex = 0
        path = nil
        open()
        startPolling()
    }

    public func disconnect() {
        wantsConnection = false
        quiet = false
        polling?.cancel()
        polling = nil
        closeSocket()
        state = .disconnected
        sessions = []
    }

    private func closeSocket() {
        generation += 1
        server.closeChannel()
    }

    /// The sign-in first — for a Mac, `hello` over HTTP, which lets this
    /// device in on the network's word or on the password — then the live
    /// channel. A refusal is the server asking the user to sign in: no
    /// retrying until the record changes.
    private func open() {
        guard wantsConnection else { return }
        closeSocket()
        if !quiet { state = .connecting }
        let mine = generation
        let server = server
        if pathIndex == 0 || paths.isEmpty { paths = pathsToTry() }
        guard !paths.isEmpty else {
            note("no path this device can take: the computer is known only over SSH")
            wantsConnection = false
            state = .failed("This computer is reached only over SSH, which this app cannot use. Add it by its connection code (not the SSH one), or by its URL.")
            return
        }
        let path = paths[min(pathIndex, paths.count - 1)]
        var record = record
        record.address = path
        let started = log.now()
        // A path on the network the device is on answers in milliseconds
        // or not at all: on the first round it is given less time, and the
        // next path is tried sooner.
        let timeouts = paths.map { attempt == 0 && Self.fit(of: $0) == .local ? Self.localSignInTimeout : Self.signInTimeout }
        let timeout = timeouts[min(pathIndex, paths.count - 1)]
        // Every path in the round at once, each a moment after the one
        // before, where the server signs in so: the round is one try.
        let racing = server.racesPaths && pathIndex == 0 && paths.count > 1
        let candidates = paths
        // SSH, the way in, has longer alone: its handshake takes longer.
        let headStarts = paths.map { SSHAddress($0) != nil ? Self.sshHeadStart : Self.headStart }
        let limit = racing ? headStarts.dropLast().reduce(0, +) + (timeouts.max() ?? Self.signInTimeout) + 1_000 : timeout
        note("signing in" + (attempt > 0 ? " (retry \(attempt))" : "")
             + (racing ? " by the first to answer of \(paths.joined(separator: ", "))" : " by \(path)") + (quiet ? ", still shown connected" : ""))
        signingIn = mine
        Task { [weak self] in
            do {
                let (name, path) = racing
                    ? try await server.authenticate(record, byFirstOf: candidates, headStarts: headStarts, timeouts: timeouts)
                    : (try await server.authenticate(record), path)
                guard let self, self.generation == mine, self.wantsConnection else { return }
                self.signingIn = nil
                self.note("signed in after \(self.log.since(started)) ms; opening the channel")
                self.path = path
                self.lastGoodPath = path
                self.pathIndex = 0
                if let name { self.record.takeServerName(name) }
                if let identity = server.identity { self.take(identity) }
                // Standing alone, signed in by a path that is not its
                // address (one learned before it said so): that sign-in is
                // let go, and it is reached at its address from now on.
                if self.isolated, path != self.record.address {
                    self.note("stands alone: reached at \(self.record.address) only, not by \(path)")
                    self.lastGoodPath = nil
                    self.paths = []
                    server.closeChannel()
                    self.connect()
                    return
                }
                self.openChannel(mine)
            } catch {
                guard let self, self.generation == mine, self.wantsConnection else { return }
                self.signingIn = nil
                if error as? AgentServerError == .needsAuthentication {
                    self.note("sign-in refused after \(self.log.since(started)) ms: needs signing in")
                    self.wantsConnection = false
                    self.quiet = false
                    self.state = .needsAuthentication
                } else {
                    self.note("sign-in failed after \(self.log.since(started)) ms")
                    // Raced, the round is over: no path is left to step to.
                    if racing { self.pathIndex = self.paths.count - 1 }
                    self.dropped("\(error)")
                }
            }
        }
        // A sign-in that never answers (a request riding a connection that
        // died while the app was away) is given up on, not waited out.
        Task { [weak self] in
            await server.delay(milliseconds: limit)
            guard let self, self.signingIn == mine, self.generation == mine else { return }
            self.signingIn = nil
            self.note("no answer to the sign-in by \(racing ? "any path" : path) in \(limit) ms")
            if racing { self.pathIndex = self.paths.count - 1 }
            self.dropped("No answer to the sign-in")
        }
    }

    /// How long one path has to answer before the next starts beside it,
    /// where the server signs in by several at once; an SSH path longer.
    static let headStart: Int32 = 400
    static let sshHeadStart: Int32 = 1_000

    /// How long a sign-in has to answer before the try is given up; on
    /// the first round, a path on the device's own network has less.
    static let signInTimeout: Int32 = 5_000
    static let localSignInTimeout: Int32 = 2_000

    /// The paths for a round: the record's own paths ranked by fit — a
    /// path on a network the device is on now first (the LAN at home),
    /// then overlay-network ones (a tailnet) while the device has such a
    /// network, then the rest, with the one that answered last time and
    /// then the record's address first among equals. Where the device has SSH and the computer an SSH
    /// path, SSH is the way in: its paths that fit (the LAN's, the
    /// tailnet's) before any other, the rest only when SSH does not
    /// answer. A device without SSH (a browser) skips SSH paths.
    func pathsToTry() -> [String] {
        // Standing alone: the address it was added at, and no other.
        if isolated { return [record.address] }
        var candidates: [String] = []
        let canSSH = VisorHost.ssh != nil
        let own = record.allPaths.filter { canSSH || SSHAddress($0) == nil }
        let preferSSH = canSSH && own.contains { SSHAddress($0) != nil }
        let tiers: [(PathFit, Bool?)] = preferSSH
            ? [(.local, true), (.overlay, true), (.local, false), (.overlay, false), (.other, true), (.other, false),
               (.unlikely, true), (.unlikely, false)]
            : [(.local, nil), (.overlay, nil), (.other, nil), (.unlikely, nil)]
        for (fit, ssh) in tiers {
            var tier = own.filter { Self.fit(of: $0) == fit && (ssh == nil || (SSHAddress($0) != nil) == ssh) }
            // The one that answered last time first among its equals.
            if let lastGoodPath, let index = tier.firstIndex(of: lastGoodPath) {
                tier.remove(at: index)
                tier.insert(lastGoodPath, at: 0)
            }
            candidates += tier
        }
        var out: [String] = []
        for path in candidates where !out.contains(path) { out.append(path) }
        // Nothing found: the address — unless it is SSH, which this
        // device cannot take (it is no URL either). Then none.
        if out.isEmpty, canSSH || SSHAddress(record.address) == nil { return [record.address] }
        return out
    }

    /// The server stands alone — it says so, or its authenticator makes
    /// it so (`AgentServerAuthenticator.isolated`): reached only at the
    /// record's address, its other paths kept from everything else, and
    /// out of the relay.
    public var isolated: Bool {
        record.standalone || AgentServerAuthenticators.authenticator(for: record).isolated
    }

    /// How a path fits where the device is now.
    enum PathFit { case local, overlay, other, unlikely }

    static func fit(of path: String) -> PathFit {
        guard let network = VisorHost.network, let host = Self.host(ofPath: path) else { return .other }
        if network.isOnLocalNetwork(host) { return .local }
        if Self.isOverlay(host) { return network.hasVPN ? .overlay : .unlikely }
        if Self.isPrivate(host) { return .unlikely }
        return .other
    }

    /// A path's host: the SSH target's, or the URL's.
    static func host(ofPath path: String) -> String? {
        if let ssh = SSHAddress(path) { return ssh.target.host }
        return ServerAddress(path).flatMap { host(of: $0.root) }
    }

    /// 100.64.0.0/10: a tailnet's addresses.
    static func isOverlay(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// 10/8, 172.16/12, 192.168/16: a LAN's addresses, reachable only
    /// from it; and 169.254/16, a link's own (a cable between two Macs).
    static func isPrivate(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 169 && parts[1] == 254)
    }

    /// The device's networks changed: a server not connected is tried
    /// now, from the start; one connected by a path that no longer fits
    /// best (over the tailnet, now that the LAN is back; over the LAN,
    /// now left) is connected again by the one that does.
    public func networkChanged() {
        guard wantsConnection else { return }
        let best = pathsToTry().first
        if state == .connected, let path, path == best { return }
        // Already on its way in by the path that fits best (the system's
        // first word at launch, as the first sign-in runs): left to finish.
        let trying = path ?? (signingIn != nil && paths.indices.contains(pathIndex) ? paths[pathIndex] : nil)
        if state == .connecting || quiet, let trying, trying == best {
            note("the networks changed: already connecting by \(trying)")
            return
        }
        note("the networks changed: connecting by \(best ?? record.address)" + (state == .connected ? " instead of \(path ?? ""), still shown connected" : ""))
        // Connected by a path that no longer fits best: moved underneath,
        // still shown as connected.
        if state == .connected, !quiet {
            quiet = true
            holdQuietly()
        }
        attempt = 0
        pathIndex = 0
        open()
    }

    /// What the server said of itself: its id, and its own addresses as
    /// more paths to it.
    private func take(_ identity: ServerIdentity) {
        serverVersion = identity.version
        var changed = false
        if record.serverID != identity.id { record.serverID = identity.id; changed = true }
        if record.standalone != identity.standalone {
            record.standalone = identity.standalone
            changed = true
        }
        // Standing alone: the paths learned before it said so go too.
        if isolated {
            if !record.paths.isEmpty { record.paths = []; changed = true }
            if changed { onRecordChange?() }
            return
        }
        if record.takePaths(identity.addresses) { changed = true }
        if changed { onRecordChange?() }
    }

    /// The server's SSH paths, as it said them.
    public var sshPaths: [String] { record.allPaths.filter { SSHAddress($0) != nil } }

    /// Makes SSH the way in: the record's address becomes the server's
    /// SSH path (the one on the same host as now, else the first), the
    /// address until now one of the other paths, and the connection is
    /// made again — over SSH if the server knows this device's key, else
    /// by another path first, after which the key is handed over and SSH
    /// tried again (`enrollSSHIfWanted`). False when no SSH path is known.
    @discardableResult
    public func useSSH() -> Bool {
        let host = ServerAddress(record.address).flatMap { Self.host(of: $0.root) }
        guard let chosen = sshPaths.first(where: { SSHAddress($0)?.target.host == host }) ?? sshPaths.first else { return false }
        update { record in
            let before = record.address
            record.address = chosen
            record.learnPaths([before])
        }
        lastGoodPath = nil
        sshEnrolled = false
        connect()
        return true
    }

    /// The host part of a URL root (`http://10.0.0.2:7433` → `10.0.0.2`).
    static func host(of root: String) -> String? {
        guard let range = root.range(of: "://") else { return nil }
        let rest = root[range.upperBound...]
        let hostPort = rest.prefix { $0 != "/" }
        if hostPort.hasPrefix("[") { return String(hostPort.prefix { $0 != "]" }.dropFirst()) }
        return String(hostPort.prefix { $0 != ":" })
    }

    /// Connected by another path while the computer has SSH paths (SSH
    /// being the way in where the device has it): this device's key is
    /// handed to the server, and SSH tried again — once.
    private func enrollSSHIfWanted() {
        guard !isolated, !sshPaths.isEmpty, let path, SSHAddress(path) == nil, !sshEnrolled,
              let ssh = VisorHost.ssh else { return }
        sshEnrolled = true
        let server = server
        let key = ssh.publicKey()
        let mine = generation
        Task { [weak self] in
            do {
                try await server.authorizeSSHKey(key)
                guard let self, self.generation == mine else { return }
                self.note("this device's SSH key was authorized; connecting over SSH, still shown connected")
                self.lastGoodPath = nil
                if self.state == .connected {
                    self.quiet = true
                    self.holdQuietly()
                }
                self.connect()
            } catch {
                self?.note("the SSH key was not authorized: \(error)")
            }
        }
    }
    /// The try (by its generation) whose sign-in is still unanswered.
    private var signingIn: Int?
    private var log: ConnectionLog { ConnectionLog.shared }
    /// When the channel now being opened was asked for, for the log.
    private var channelAsked = 0.0

    /// One line in the connection log, about this server.
    func note(_ message: String) {
        log.note(record.name.isEmpty ? record.address : record.name, message)
    }

    private func openChannel(_ mine: Int) {
        channelAsked = log.now()
        server.openChannel { [weak self] event in
            // A channel closed and reopened since: what the old one says
            // is no longer ours.
            guard let self, self.generation == mine else { return }
            switch event {
            case .closed(let reason): self.dropped(reason)
            default: self.handle(event)
            }
        }
    }

    /// The app came back to the front. Whatever was waiting to retry was
    /// not running while it was away: so a server that is not connected is
    /// tried again now, from the start of the schedule. One that was
    /// connected still shows so, and its channel is asked whether it is
    /// there (a phone's may have died while the app was away); one that
    /// does not answer is opened again underneath, and shown otherwise only
    /// if that fails. A server waiting for the user to sign in is left
    /// alone.
    ///
    /// Every server is tried at the same moment, each on its own; a try
    /// that fails is followed by the schedule from its start (2, 4, 8…).
    public func resume() {
        guard wantsConnection else {
            note("back in front: left alone (\(state.label))")
            return
        }
        if quiet { return note("back in front: already opening the channel again") }
        // On its way in already (the launch's own first try, as the app
        // first comes to the front): left to finish, not started over.
        if state == .connecting { return note("back in front: already connecting") }
        guard state == .connected else {
            note("back in front: connecting now (was \(state.label))")
            attempt = 0
            open()
            return
        }
        note("back in front: asking the open channel whether it is there")
        let mine = generation
        let server = server
        let asked = log.now()
        Task { [weak self] in
            let alive = await server.verifyChannel()
            guard let self, self.generation == mine, self.wantsConnection, self.state == .connected else { return }
            guard !alive else { return self.note("the channel answered in \(self.log.since(asked)) ms") }
            self.dropped("No answer to a heartbeat on coming back")
        }
    }

    /// The app left the front. The schedule starts over, so nothing that
    /// was waiting out a long retry is still waiting when the app is back.
    public func suspend() {
        guard wantsConnection else { return }
        note("app in the background: retry schedule reset (was \(state.label), retry \(attempt))")
        attempt = 0
    }

    /// How often the server is asked for its sessions outright.
    static let pollInterval: Int32 = 60_000
    private var polling: Task<Void, Never>?

    /// The backup for the live channel: every minute the server is asked
    /// for its sessions over its one-shot side. With the channel up, the
    /// answer is taken as a list the channel would have brought (so one it
    /// failed to bring is not missed for long); with the channel down and
    /// the server answering, the channel is opened again at once rather
    /// than at the next retry.
    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let server = self?.server else { return }
                await server.delay(milliseconds: Self.pollInterval)
                guard let self, !Task.isCancelled, self.wantsConnection else { continue }
                guard let list = try? await server.sessions(), !Task.isCancelled, self.wantsConnection else {
                    self.note("minute poll: no answer (\(self.state.label))")
                    continue
                }
                switch self.state {
                case .connected: self.handle(.sessions(list))
                case .offline:
                    self.note("minute poll: the server answers while the channel is down; connecting now")
                    self.attempt = 0
                    self.open()
                default: break
                }
            }
        }
    }

    /// How long to wait before the next try after a drop, in seconds:
    /// 2, 4, 8, 16, then every 30.
    static func retryDelay(afterAttempt attempt: Int) -> Int {
        attempt >= 5 ? 30 : 1 << max(1, attempt)
    }

    /// How long a channel opened again underneath may take before the
    /// server is shown as connecting: a little more than a sign-in has.
    static let quietHold: Int32 = 6_000
    private var quietTries = 0

    /// Shows the server as connecting once the channel opened again
    /// underneath has taken `quietHold`, if it is still being opened.
    private func holdQuietly() {
        quietTries += 1
        let mine = quietTries
        Task { [weak self] in
            await self?.server.delay(milliseconds: Self.quietHold)
            guard let self, self.quiet, self.quietTries == mine else { return }
            self.note("the channel is taking a while: shown as connecting")
            self.quiet = false
            self.state = .connecting
        }
    }

    private func dropped(_ reason: String) {
        generation += 1
        server.closeChannel()
        // A channel that was up, gone: opened again at once, by the paths
        // from the best, and still shown as connected — which it is taken
        // to be until every path has failed, or it takes too long.
        if wantsConnection, state == .connected, !quiet {
            note("dropped: \(reason); opening it again at once, still shown connected")
            quiet = true
            attempt = 0
            pathIndex = 0
            path = nil
            holdQuietly()
            open()
            return
        }
        // Another path to the same server is tried at once; the wait
        // comes once every path has been.
        if wantsConnection, path == nil, pathIndex + 1 < paths.count {
            pathIndex += 1
            note("dropped: \(reason); trying \(paths[pathIndex])" + (quiet ? ", still shown connected" : ""))
            open()
            return
        }
        quiet = false
        if case .failed = state {} else { state = wantsConnection ? .offline(reason) : .disconnected }
        for transcript in transcripts.values { transcript.busy = false; transcript.activity = nil }
        guard wantsConnection else {
            note("dropped: \(reason); not retrying")
            return
        }
        pathIndex = 0
        path = nil
        attempt += 1
        let wait = Int32(Self.retryDelay(afterAttempt: attempt) * 1000)
        note("dropped: \(reason); retry \(attempt) in \(wait / 1000) s")
        let mine = generation
        Task { [weak self] in
            await self?.server.delay(milliseconds: wait)
            guard let self, self.wantsConnection, self.generation == mine else { return }
            self.open()
        }
    }

    private func handle(_ event: AgentServerEvent) {
        switch event {
        case .welcome(let name, let list, let catalogs, let containers):
            containersAvailable = containers
            note("connected: welcome \(log.since(channelAsked)) ms after the channel was asked for, \(list.count) sessions")
            quiet = false
            state = .connected
            live = true
            attempt = 0
            record.takeServerName(name)
            if !record.everConnected { record.everConnected = true }
            sessions = list
            saveCachedSessions()
            onSessionsChange?()
            self.catalogs = catalogs
            onConnected?()
            enrollSSHIfWanted()
            // Re-subscribe to whatever was open before the drop.
            // The sessions open here (not those left and let go of).
            for id in pendingSubscriptions.union(transcripts.keys.filter { releasing[$0] == nil && transcripts[$0]?.released != true }) {
                server.subscribe(id)
            }
            pendingSubscriptions.removeAll()
            askEarlierAgain()
            // A folder may have been renamed or moved while we were away.
            Task { await refreshMissing() }
            if server.starting.fromChoices { Task { await loadStartChoices() } }
            registerForPush()
        case .catalogs(let catalogs):
            self.catalogs = catalogs
        case .relay:
            onRelay?()
        case .transport(let live):
            if self.live != live { note(live ? "following live" : "following by polling") }
            self.live = live
        case .account(let account, let agent):
            if let index = catalogs.firstIndex(where: { $0.agent == agent }) { catalogs[index].account = account }
        case .refused(let message):
            note("login refused: \(message)")
            wantsConnection = false
            quiet = false
            state = .needsAuthentication
        case .failed(let message):
            note("the server answered with an error: \(message)")
            quiet = false
            state = .failed(message)
        case .sessions(let list, let containers):
            if let containers { containersAvailable = containers }
            let before = sessions
            sessions = list
            if state == .connected { notifyChanges(from: before, to: sessions) }
            onSessionsChange?()
            saveCachedSessions()
            // Words sent while the agent was busy come back in its queue; a
            // goal command, in the session's goal.
            for session in sessions {
                transcripts[session.id]?.settleSending()
                transcripts[session.id]?.settleGoal(session.goal)
            }
        case .closed:
            break
        case .session(let envelope):
            guard let id = envelope.session else { return }
            if envelope.type == "earlier" { return takeEarlier(envelope, for: id) }
            transcript(for: id).apply(envelope)
            // Working or not, as the session itself says it: the list shows
            // the same at once, rather than whatever the last list said (a
            // reply from before the turn began can arrive after it).
            if envelope.type == "busy" || envelope.type == "ephemeral", let busy = envelope.busy,
               let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].busy != busy {
                sessions[index].busy = busy
            }
        }
    }

    /// The rows already seen, by host and session: on disk where there
    /// is SQLite, so a session opens as it was last seen and syncs only
    /// what changed since; in memory on the web.
    static var cache: MessageCache = .open(named: "messages")
    /// Where the cache is written, and read past what is shown: off the
    /// main actor, in order.
    static let cacheQueue = CacheQueue()
    func cacheKey(_ sessionID: String) -> String { id + "/" + sessionID }

    /// How many rows a thread opens with (from this device's cache, at once;
    /// from the server, the first time), and how many go in each page after.
    static let initialRows = 100
    static let pageRows = 50

    public func transcript(for sessionID: String) -> SessionTranscript {
        if let existing = transcripts[sessionID] { return existing }
        let transcript = SessionTranscript()
        let key = cacheKey(sessionID)
        fill(transcript, from: key)
        transcript.keep = { write, state in
            let cache = Self.cache
            Self.cacheQueue.write {
                Self.write(write, to: cache, key: key)
                try? cache.setSyncState(state, for: key)
            }
        }
        transcript.info = sessions.first { $0.id == sessionID }
        transcripts[sessionID] = transcript
        startSyncing(sessionID, transcript)
        return transcript
    }

    /// As last seen, at once, from this device's cache; the sync then asks
    /// only for what moved.
    private func fill(_ transcript: SessionTranscript, from key: String) {
        let kept = Self.cache.messages(in: key, limit: Self.initialRows)
        guard !kept.messages.isEmpty, let state = Self.cache.syncState(of: key) else { return }
        transcript.entries = kept.messages
        transcript.hasEarlier = kept.more
        transcript.revision = state.revision
        transcript.generation = state.generation
        transcript.loaded = true
    }

    /// A sync's change, written to the cache as a change: every row synced
    /// or paged to stays kept, and a thread reads back offline as far as it
    /// was ever seen.
    nonisolated static func write(_ write: SessionTranscript.CacheWrite, to cache: MessageCache, key: String) {
        switch write {
        case .upsert(let rows, let removed):
            try? cache.remove(removed, in: key)
            try? cache.append(key, rows)
        case .rewrite(let from, let rows, let all):
            if (try? cache.replace(key, from: from, with: rows)) != true { try? cache.replace(key, with: all) }
        case .follow(let after, let rows):
            if (try? cache.replace(key, after: after, with: rows)) != true { try? cache.replace(key, with: rows) }
        case .replace(let rows):
            try? cache.replace(key, with: rows)
        }
    }

    /// The transcript syncs apart from the live channel: each request
    /// names the revision held and is answered when the rows have moved
    /// past it (or after a while, with the same), and the answer brings the
    /// rows held up to date — so a dropped channel message, a sleep, a
    /// restart of the server all heal on the next answer. Runs while the
    /// session is open, and a little after it is left (`leave`).
    private var syncing: [String: Task<Void, Never>] = [:]

    private func startSyncing(_ sessionID: String, _ transcript: SessionTranscript) {
        guard syncing[sessionID] == nil else { return }
        let server = server
        syncing[sessionID] = Task { [weak self, weak transcript] in
            while !Task.isCancelled {
                guard let transcript else { return }
                let revision = transcript.revision
                // Catching up: the next page of what changed since the
                // revision held, after the last row given.
                let catchUp = transcript.catchUp
                do {
                    let asked = ContinuousClock.now
                    let envelope = try await server.transcript(of: sessionID, since: catchUp?.since ?? revision,
                                                                generation: transcript.generation, after: catchUp?.after)
                    guard !Task.isCancelled else { return }
                    guard transcript.takes(envelope) else {
                        // Nothing new, and not held as a server holds it
                        // (a front, a stand-in): a breath before asking
                        // again, rather than asking as fast as it answers.
                        if ContinuousClock.now - asked < .seconds(1) { try? await Task.sleep(for: .seconds(1)) }
                        continue
                    }
                    let shown = transcript.shownIDs, generation = transcript.generation
                    let whole = envelope.reset == true || envelope.generation.map { $0 != generation } ?? false
                    transcript.sync(envelope)
                    if let change = ThreadChange(before: shown, after: transcript.shownIDs, whole: whole,
                                                 generation: (generation, transcript.generation),
                                                 revision: (revision, transcript.revision)) {
                        self?.note("thread \(sessionID.prefix(8)): \(change)")
                    }
                } catch {
                    // The server is away, or a hold timed out on the way:
                    // ask again shortly.
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    /// Opens a session's transcript for a screen that shows it: its rows
    /// sync, and its state (working, status lines, an approval asked for)
    /// follows over the socket. A session left and let go of reads its
    /// latest rows from the cache again, and syncs on from there. Each
    /// screen is counted, and the session is let go of only when none
    /// shows it (`leave`).
    public func subscribe(_ sessionID: String) {
        onScreen[sessionID, default: 0] += 1
        follow(sessionID)
    }

    /// A screen found its session let go of while it shows it: taken up
    /// again at once (the screen is counted already).
    public func takeUp(_ sessionID: String) {
        guard transcripts[sessionID]?.released == true else { return }
        note("thread \(sessionID.prefix(8)): let go of while on screen; taken up again")
        follow(sessionID)
    }

    /// How many screens show each session. A screen built again can appear
    /// before the one it replaces goes, so a session is let go of only once
    /// the count is back to none.
    private var onScreen: [String: Int] = [:]

    private func follow(_ sessionID: String) {
        releasing.removeValue(forKey: sessionID)?.cancel()
        let transcript = transcript(for: sessionID)
        if transcript.released {
            transcript.released = false
            fill(transcript, from: cacheKey(sessionID))
            startSyncing(sessionID, transcript)
        }
        // The agent's commands, known before a message is sent: a message
        // with a command after some words is split where it is typed.
        if sessionCommands[sessionID] == nil { Task { [weak self] in _ = await self?.loadCommands(for: sessionID) } }
        if state == .connected { server.subscribe(sessionID) } else { pendingSubscriptions.insert(sessionID) }
    }

    /// How long a session left is kept as it is, so going back to it at
    /// once (a sheet, a quick look at another) costs nothing.
    static let releaseDelay: Duration = .seconds(20)
    private var releasing: [String: Task<Void, Never>] = [:]

    /// The session is no longer on screen: a little later, unless it is
    /// opened again, its rows go from memory (the cache keeps them), its
    /// sync stops, and the server stops sending its state.
    public func leave(_ sessionID: String) {
        guard transcripts[sessionID] != nil else { return }
        let left = max(0, (onScreen[sessionID] ?? 0) - 1)
        onScreen[sessionID] = left == 0 ? nil : left
        guard left == 0 else { return note("thread \(sessionID.prefix(8)): one screen of it gone, \(left) still showing it") }
        releasing.removeValue(forKey: sessionID)?.cancel()
        releasing[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseDelay)
            guard !Task.isCancelled else { return }
            self?.release(sessionID)
        }
    }

    func release(_ sessionID: String) {
        releasing[sessionID] = nil
        // Shown again since, or the session the app is showing: kept.
        guard onScreen[sessionID] == nil else { return }
        if let viewing = VisorNotificationHandler.shared.viewing, viewing.session == sessionID, viewing.computer == record.address {
            return note("thread \(sessionID.prefix(8)): on screen, kept")
        }
        syncing.removeValue(forKey: sessionID)?.cancel()
        pendingSubscriptions.remove(sessionID)
        if state == .connected { server.unsubscribe(sessionID) }
        guard let transcript = transcripts[sessionID] else { return }
        transcript.released = true
        transcript.release()
        note("thread \(sessionID.prefix(8)): left, its rows let go of")
    }

    /// The user has read what the session had to tell them.
    public func acknowledge(_ sessionID: String) {
        transcript(for: sessionID).notice = nil
        server.acknowledge(sessionID)
    }

    // MARK: Projects

    /// A folder on the host and the sessions running in it.
    public struct Project: Identifiable, Hashable {
        public var cwd: String
        public var sessions: [SessionInfo]
        /// Ended sessions kept in this folder: they can come back or go.
        public var archived: [SessionInfo] = []
        /// What the user calls this folder, if not its own name. Kept on
        /// this device against the folder's path, so it follows the
        /// project rather than any one session.
        public var alias: String?
        /// The folder was renamed or moved out from under us: the server
        /// says there is nothing there now.
        public var missing = false
        /// Nothing left here, so the folder can be forgotten.
        public var isEmpty: Bool { sessions.isEmpty && archived.isEmpty }

        public init(cwd: String, sessions: [SessionInfo], archived: [SessionInfo] = [],
                    alias: String? = nil, missing: Bool = false) {
            self.cwd = cwd
            self.sessions = sessions
            self.archived = archived
            self.alias = alias
            self.missing = missing
        }
        public var id: String { cwd }
        /// The folder's own name on disk.
        public var folderName: String {
            let path = cwd.hasSuffix("/") && cwd.count > 1 ? String(cwd.dropLast()) : cwd
            if path == "~" || path.isEmpty { return "Home" }
            return path.split(separator: "/").last.map(String.init) ?? path
        }
        /// What to show: the alias when there is one.
        public var name: String {
            if let alias, !alias.isEmpty { return alias }
            return folderName
        }
    }

    /// Folders the user added without a session yet (kept on this device).
    public private(set) var knownProjects: [String] = []
    /// The names the user gave folders, by path (this device only).
    public private(set) var projectAliases: [String: String] = [:]
    /// Folders the server says are no longer there.
    public private(set) var missingProjects: Set<String> = []

    /// The server's projects: every known folder and every folder with a
    /// live session, in the order they were added.
    public var projects: [Project] {
        var order: [String] = knownProjects
        for session in sessions where !order.contains(session.cwd) { order.append(session.cwd) }
        return order.map { cwd in
            Project(cwd: cwd,
                    sessions: activeSessions.filter { $0.cwd == cwd },
                    archived: archivedSessions.filter { $0.cwd == cwd },
                    alias: projectAliases[cwd] ?? startChoices.first { $0.id == cwd }?.title,
                    missing: missingProjects.contains(cwd))
        }
    }

    /// Without the whitespace around it. wasm's Foundation has no
    /// trimmingCharacters; the client builds for the browser too.
    static func trimmed(_ text: String) -> String {
        var slice = Substring(text)
        while let first = slice.first, first.isWhitespace || first.isNewline { slice = slice.dropFirst() }
        while let last = slice.last, last.isWhitespace || last.isNewline { slice = slice.dropLast() }
        return String(slice)
    }

    /// Names a project. An empty name gives the folder its own name back.
    public func renameProject(_ cwd: String, to name: String) {
        let trimmed = Self.trimmed(name)
        if trimmed.isEmpty { projectAliases.removeValue(forKey: cwd) } else { projectAliases[cwd] = trimmed }
        saveProjects()
    }

    /// Points a project at the folder it moved to: the alias follows it,
    /// and the server moves the sessions that ran there.
    public func relocateProject(_ cwd: String, to destination: String) {
        let alias = projectAliases[cwd]
        projectAliases.removeValue(forKey: cwd)
        if let alias { projectAliases[destination] = alias }
        if let index = knownProjects.firstIndex(of: cwd) { knownProjects[index] = destination }
        else if !knownProjects.contains(destination) { knownProjects.append(destination) }
        missingProjects.remove(cwd)
        saveProjects()
        perform { [weak self] in
            let list = try await self?.server.relocateSessions(from: cwd, to: destination) ?? []
            self?.take(list, replacing: false)
        }
        Task { await refreshMissing() }
    }

    /// Forgets a project and every session in it.
    public func removeProjectAndSessions(_ cwd: String) {
        for session in sessions where session.cwd == cwd { end(session.id) }
        removeProject(cwd)
    }

    /// Asks the server which of our folders are still there. Cheap (one
    /// question per project) and only worth doing when connected.
    public func refreshMissing() async {
        // A server's own choices are not folders to look for.
        guard state == .connected, !server.starting.fromChoices else { return }
        var gone: Set<String> = []
        for cwd in Set(projects.map(\.cwd)) {
            guard let there = try? await folderExists(cwd) else { continue }
            if !there { gone.insert(cwd) }
        }
        missingProjects = gone
    }

    public func addProject(_ cwd: String) {
        guard !knownProjects.contains(cwd) else { return }
        knownProjects.append(cwd)
        saveProjects()
    }

    public func removeProject(_ cwd: String) {
        knownProjects.removeAll { $0 == cwd }
        projectAliases.removeValue(forKey: cwd)
        missingProjects.remove(cwd)
        saveProjects()
    }

    /// What was listed last time. Shown while the connection is being
    /// made, so relaunching does not empty the sidebar and fill it again
    /// a second later. Every session reads as not-connected until the
    /// server answers, which is what the yellow dot says.
    func loadCachedSessions() {
        // The canned server keeps nothing: every run starts the same.
        guard !VisorFixture.active else { return }
        let saved = VisorHost.settings?.get(key: "sessions." + id) ?? ""
        guard !saved.isEmpty, let list = parseJSON(saved)?.array?.compactMap(SessionInfo.init(json:)) else { return }
        sessions = list.map { info in
            var quiet = info
            // Nothing can be running: we are not even connected yet.
            quiet.busy = false
            quiet.pendingApproval = nil
            return quiet
        }
    }

    private func saveCachedSessions() {
        // The canned server keeps nothing: every run starts the same.
        guard !VisorFixture.active else { return }
        VisorHost.settings?.set(key: "sessions." + id, value: JSONValue.array(sessions.map(\.json)).encoded())
    }

    func loadProjects() {
        // The canned server keeps nothing: every run starts the same.
        guard !VisorFixture.active else { return }
        let saved = VisorHost.settings?.get(key: "projects." + id) ?? ""
        knownProjects = parseJSON(saved)?.array?.compactMap(\.string) ?? []
        let names = VisorHost.settings?.get(key: "projectNames." + id) ?? ""
        var aliases: [String: String] = [:]
        for entry in parseJSON(names)?.array ?? [] {
            guard let cwd = entry["cwd"].string, let name = entry["name"].string else { continue }
            aliases[cwd] = name
        }
        projectAliases = aliases
    }

    private func saveProjects() {
        // The canned server keeps nothing: every run starts the same.
        guard !VisorFixture.active else { return }
        VisorHost.settings?.set(key: "projects." + id, value: JSONValue.array(knownProjects.map(JSONValue.string)).encoded())
        let names = projectAliases.keys.sorted().map { cwd in
            JSONValue.object(["cwd": .string(cwd), "name": .string(projectAliases[cwd] ?? "")])
        }
        VisorHost.settings?.set(key: "projectNames." + id, value: JSONValue.array(names).encoded())
    }

    public func sendMessage(_ sessionID: String, text: String, images: [String] = []) {
        // Without the whitespace around it, which is how the record keeps
        // it (and a phone's keyboard leaves a space after the last word).
        let text = Self.trimmed(text)
        // A sign-in waiting for its code (`/login`): these words are the
        // code, for the sign-in, and nothing for the agent or the thread.
        if transcripts[sessionID]?.signIn != nil, !text.hasPrefix("/"), images.isEmpty {
            server.signIn(sessionID, code: text)
            note("thread \(sessionID.prefix(8)): a sign-in code sent")
            return
        }
        // A slash command on a line of its own after some words: Claude
        // Code takes it as the command only at the start of a message, so
        // the words go first and the command after them, as the terminal
        // treats it. The agent's commands are known from when the session
        // was opened; where they are not yet, they are asked for first.
        if text.contains("\n/"), sessionCommands[sessionID] == nil {
            Task { [weak self] in
                guard let self else { return }
                _ = await self.loadCommands(for: sessionID)
                self.sendParts(sessionID, text: text, images: images)
            }
            return
        }
        sendParts(sessionID, text: text, images: images)
    }

    /// Puts a message — or its words and then its command — in the thread
    /// now, in the same update as the draft it came from clearing (a frame
    /// later and the thread has already moved for the composer's lines),
    /// and then posts each part in order.
    private func sendParts(_ sessionID: String, text: String, images: [String]) {
        let parts = text.contains("\n/") ? Self.split(text, commands: Set((sessionCommands[sessionID] ?? []).map(\.name))) : [text]
        let session = transcript(for: sessionID)
        var posts: [(id: String, text: String, images: [String])] = []
        for (index, part) in parts.enumerated() {
            let attached = index == 0 ? images : []
            let out = outgoing(part, images: attached, in: sessionID, session)
            session.sending.append(out)
            posts.append((out.id, part, attached))
        }
        session.flush()
        Task { [weak self] in
            // One after the other: a command must reach the server after
            // its words, to wait for their turn to end.
            for post in posts { await self?.post(sessionID, outgoing: post.id, text: post.text, images: post.images) }
        }
    }

    /// One message on its way, as the thread shows it before it is on the
    /// record: sent to an idle agent, the thread's last row until the
    /// transcript syncs an identical message sent after this one; to a
    /// working one, in the composer's queue.
    private func outgoing(_ text: String, images: [String], in sessionID: String, _ session: SessionTranscript) -> SessionTranscript.Outgoing {
        let info = sessions.first { $0.id == sessionID }
        let idle = !session.busy && !(info?.busy ?? false) && (info?.queued.isEmpty ?? true) && session.sending.isEmpty
        let entry = TranscriptEntry(id: "sending-" + AgentServerRecord.newID(), role: .user, text: text, images: images)
        var outgoing = SessionTranscript.Outgoing(id: entry.id, entry: entry, sinceRevision: session.revision)
        outgoing.shown = idle
        outgoing.had = Set(session.entries.lazy.filter { $0.role == .user }.map(\.id))
        return outgoing
    }

    /// Posts one message. Taken, one that waits for the turn to end is no
    /// longer on its way: the server's queue holds it from here (one sent to
    /// an idle agent stays in the thread until the record carries it). One
    /// the server handed straight to the agent though it looked busy from
    /// here (the session's state a moment behind) goes in the thread now,
    /// as if it had looked idle, rather than nowhere until the agent's log
    /// has it, after the reply has begun. Not taken, it is not on its way
    /// at all, and the user is told.
    private func post(_ sessionID: String, outgoing id: String, text: String, images: [String]) async {
        let session = transcript(for: sessionID)
        do {
            let answer = try await server.sendMessage(sessionID, text: text, images: images)
            take(answer, replacing: false)
            // A command stays out: its log may never write it back.
            if !text.hasPrefix("/"), let info = answer.first(where: { $0.id == sessionID }), !info.queued.contains(text),
               let index = session.sending.firstIndex(where: { $0.id == id }) {
                session.sending[index].shown = true
            } else {
                session.sending.removeAll { $0.id == id && !$0.shown }
            }
            commandError = nil
        } catch {
            session.sending.removeAll { $0.id == id }
            let words = text.count > 60 ? String(text.prefix(60)) + "…" : text
            commandError = "Not sent (“\(words)”): \(error)"
        }
        session.flush()
    }

    /// The slash commands each open session's agent takes, asked once,
    /// when the session is opened: what a draft that begins with a slash
    /// is completed from, and where a message is split at a command.
    public internal(set) var sessionCommands: [String: [SlashCommand]] = [:]

    private func loadCommands(for sessionID: String) async -> [SlashCommand] {
        if let known = sessionCommands[sessionID] { return known }
        let commands = (try? await commands(for: sessionID)) ?? []
        sessionCommands[sessionID] = commands
        return commands
    }

    /// A message split at the first line that is a known slash command: the
    /// words before it, then the command with everything after it (its
    /// arguments). One part when there is no such line.
    static func split(_ text: String, commands: Set<String>) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for index in lines.indices.dropFirst() {
            let line = lines[index].drop { $0 == " " || $0 == "\t" }
            guard line.hasPrefix("/") else { continue }
            let name = String(line.dropFirst().prefix { !$0.isWhitespace })
            guard commands.contains(name) else { continue }
            let before = trimmed(lines[..<index].joined(separator: "\n"))
            let command = trimmed(lines[index...].joined(separator: "\n"))
            return before.isEmpty ? [command] : [before, command]
        }
        return [text]
    }

    public func stop(_ sessionID: String) { act(.stop, on: sessionID) }

    /// Ends the session's agent and starts it again on the same
    /// conversation: what to do with one that is stuck, or holds too much.
    public func restartAgent(_ sessionID: String) { act(.restartAgent, on: sessionID) }

    /// Ends the session's agent and keeps it ended until it is started
    /// again; what is sent meanwhile waits.
    public func stopAgent(_ sessionID: String) { act(.stopAgent, on: sessionID) }
    public func startAgent(_ sessionID: String) { act(.startAgent, on: sessionID) }

    /// Moves the session's agent into a container on its computer (`into`),
    /// or out of it onto the computer: the same folder and conversation.
    public func contain(_ sessionID: String, into: Bool) {
        perform { [weak self] in
            let list = try await self?.server.contain(session: sessionID, into: into) ?? []
            self?.take(list, replacing: false)
        }
    }

    /// The conversation went on elsewhere: keep to the branch shown (the
    /// next message carries it on and makes it the newest again), or
    /// continue the newest branch instead.
    public func keepBranch(_ sessionID: String) { act(.keepBranch, on: sessionID) }
    public func continueBranch(_ sessionID: String) { act(.continueBranch, on: sessionID) }

    /// Whether sessions move to and from this server (SessionMigration).
    public var migrates: Bool { server.migrates }

    /// Drops a message that is waiting for the turn to end — one of them,
    /// or all of them when `text` is nil.
    public func unqueue(_ sessionID: String, text: String? = nil) {
        act(.unqueue(text: text), on: sessionID)
    }

    public func setPermissions(_ sessionID: String, skip: Bool) {
        act(.permissions(skip: skip), on: sessionID)
    }

    public func setSettings(_ sessionID: String, model: String?, effort: String?) {
        act(.settings(model: model, effort: effort), on: sessionID)
    }

    public func catalog(for agent: AgentKind) -> AgentCatalog? { catalogs.first { $0.agent == agent } }

    /// What to call a session's model in the composer's pill.
    public func modelTitle(for session: SessionInfo) -> String {
        // The chosen model names the session; with no choice, the one a
        // turn actually ran on; else the agent's default.
        // (A server before 0.35 took Claude Code's "<synthetic>", the mark on
        // messages it writes itself, for a model.)
        let reported = session.reportedModel.flatMap { $0.hasPrefix("<") ? nil : $0 }
        let named = session.model ?? reported
        return catalog(for: session.agent)?.title(for: named)
            ?? named.map(AgentCatalog.prettyModelName)
            ?? session.agent.title
    }

    /// The model a session's last turn fell back to, when it is not the
    /// one chosen: shown in place of it, marked.
    public func fallbackModel(for session: SessionInfo) -> AgentModel? {
        catalog(for: session.agent)?.fallback(from: session.model, to: session.reportedModel.flatMap { $0.hasPrefix("<") ? nil : $0 })
    }

    public func approve(_ sessionID: String, id: String, allow: Bool) {
        act(.approve(id: id, allow: allow, answers: nil), on: sessionID)
    }

    /// Answers the agent's questions (AskUserQuestion), by question; nil
    /// leaves them unanswered, which the agent hears as a refusal.
    public func answer(_ sessionID: String, id: String, answers: [String: String]?) {
        act(.approve(id: id, allow: answers != nil, answers: answers), on: sessionID)
    }

    public func rename(_ sessionID: String, title: String) {
        guard localEdits == nil else { return editLocally { $0.titles[sessionID] = title } }
        act(.rename(title: title), on: sessionID)
    }

    public func archive(_ sessionID: String) {
        guard localEdits == nil else { return editLocally { $0.archived.insert(sessionID) } }
        act(.archive, on: sessionID)
    }

    public func unarchive(_ sessionID: String) {
        guard localEdits == nil else { return editLocally { $0.archived.remove(sessionID) } }
        act(.unarchive, on: sessionID)
    }

    public var activeSessions: [SessionInfo] { sessions.filter { !$0.archived } }
    public var archivedSessions: [SessionInfo] { sessions.filter(\.archived) }

    public func end(_ sessionID: String) {
        if localEdits == nil { act(.end, on: sessionID) } else { editLocally { $0.removed.insert(sessionID) } }
        transcripts.removeValue(forKey: sessionID)
        syncing.removeValue(forKey: sessionID)?.cancel()
        let cache = Self.cache, key = cacheKey(sessionID)
        Self.cacheQueue.write { try? cache.remove(key) }
    }
}
