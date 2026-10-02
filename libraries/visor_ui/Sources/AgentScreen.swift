// A session's page: AgentUI's AgentView over the session's transcript, as
// synced from the computer's record. The composer's pills attach files,
// open the model sheet (model, effort, approval mode) and show a goal, a
// loop or queued messages; Stop interrupts the turn on the computer.

import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct AgentScreen: View {
    @ObservedObject var host: HostConnection
    let sessionID: String
    @ObservedObject private var transcript: SessionTranscript
    @State private var draft = ""
    @State private var showModels = false
    /// The goal whose words are being shown, with a way to clear it.
    @State private var goalShown: String?
    @State private var loopShown = false
    /// Pictures chosen for the next message, already on the computer.
    @State private var attachments: [PickedImage] = []
    /// The attach source open (files, the photo library, the camera).
    @State private var attachSource: AttachSource?
    @State private var taking = false
    @State private var returning = false
    @State private var showInspector = false
    /// The room a terminal would have here, in points: what the window is
    /// worth in cells when this client takes control.
    @State private var paneSize: CGSize = .zero
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// The session was ended from here: the screen has nothing left to show.
    let ended: () -> Void

    init(host: HostConnection, sessionID: String, ended: @escaping () -> Void = {}) {
        self._host = ObservedObject(wrappedValue: host)
        self.sessionID = sessionID
        self.ended = ended
        self._transcript = ObservedObject(wrappedValue: host.transcript(for: sessionID))
    }

    private var info: SessionInfo? { host.sessions.first { $0.id == sessionID } }

    /// While the draft is a slash and the start of a command's name, the
    /// commands it could be, best first: names that begin with what is
    /// typed, then names that hold it.
    private var suggestions: [AgentSuggestion] {
        guard let typed = Self.commandPrefix(draft) else { return [] }
        let sorted = (host.sessionCommands[sessionID] ?? []).sorted { $0.name.lowercased() < $1.name.lowercased() }
        let starting = sorted.filter { $0.name.lowercased().hasPrefix(typed) }
        let holding = typed.isEmpty ? [] : sorted.filter { !$0.name.lowercased().hasPrefix(typed) && $0.name.lowercased().contains(typed) }
        return (starting + holding).prefix(40).map { command in
            AgentSuggestion(text: "/\(command.name) ", title: "/" + command.name,
                            detail: command.description.isEmpty ? command.argumentHint : command.description)
        }
    }

    /// What follows the slash of a draft that is only a slash command's
    /// name so far ("/co" → "co"), in lower case; nil otherwise.
    static func commandPrefix(_ draft: String) -> String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst()).lowercased()
    }

    /// The terminal is drawn only for the window it was taken with.
    private var controlsTerminal: Bool { info.map(host.controlsTerminal) ?? false }
    /// Someone else has it in the agent's own terminal.
    private var controlledElsewhere: Bool { (info?.mode.isTUI ?? false) && !controlsTerminal }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if controlsTerminal {
                    TerminalPane(host: host, sessionID: sessionID)
                } else if controlledElsewhere {
                    watching
                } else {
                    chat
                }
            }
            .onChange(of: geometry.size, initial: true) { _, size in paneSize = size }
        }
        // The title is the session's; the inspector opens from an explicit
        // button, a pane beside the chat where there is room, a sheet on a
        // phone.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showInspector.toggle() } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Session details")
                .accessibilityIdentifier("session-title")
            }
        }
        .adaptiveInspector(isPresented: $showInspector, compact: sizeClass == .compact) {
            if let info {
                SessionInspector(host: host, session: info, window: paneSize, compact: sizeClass == .compact,
                                 takeControl: { cols, rows in host.assumeControl(sessionID, cols: cols, rows: rows) },
                                 close: { showInspector = false },
                                 archive: { showInspector = false; host.archive(sessionID) },
                                 end: { showInspector = false; host.end(sessionID); ended() })
            }
        }
        .navigationTitle(sessionTitle)
        // The terminal is black; a bar drawn over it keeps its title
        // legible only in the dark palette.
        .terminalBarScheme(controlsTerminal)
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            host.subscribe(sessionID)
            // Screenshot tests: the inspector or the model picker, open —
            // once the screen has arrived and the thread has settled on
            // its last row (its second scroll comes 0.3 s after the rows),
            // so the chat behind a sheet is the same every run.
            let screen = VisorFixture.screen
            if screen == "inspector" || screen == "models" {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) {
                        if screen == "inspector" { showInspector = true } else { showModels = true }
                    }
                }
            }
        }
        // Whatever changed the mode, the inspector does not outlive the
        // screen it was opened over.
        .onChange(of: info?.mode) { showInspector = false }
        // The session was forked elsewhere and the chat moved to the newer
        // branch: not a choice, but not a surprise either.
        .alert("This session was forked", isPresented: Binding(get: { transcript.notice != nil }, set: { if !$0 { host.acknowledge(sessionID) } })) {
            Button("OK") { host.acknowledge(sessionID) }
        } message: {
            Text(transcript.notice ?? "")
        }
    }

    private var chat: some View {
        AgentView(
            messages: rows,
            // The road to the computer, when it is down, says more than
            // what the turn was last heard doing.
            status: connectionStatus == nil ? transcript.turnStatus.map(ActivityItem.init) : [],
            activity: connectionStatus ?? transcript.activity,
            error: transcript.error,
            emptyTitle: transcript.loaded ? (info?.archived == true ? "Archived" : "What should we do?") : "Loading…",
            emptyBody: transcript.loaded
                ? "Write the first message below; \(info?.agent.title ?? "the agent") starts in \(info?.cwd ?? "its directory")."
                : "Fetching the transcript from \(host.config.name).",
            draft: $draft,
            placeholder: "Message \(info?.agent.title ?? "the agent")…",
            busy: transcript.busy,
            // The send button spins only for what is not in the thread yet.
            sending: transcript.sending.contains { !$0.shown },
            attachmentCount: attachments.count,
            send: send,
            stop: { host.stop(sessionID) },
            steer: {
                // Queued first, then the turn is cut short: the host hands
                // the queue over as soon as the agent falls idle, so there
                // is no race between stopping and saying it.
                send()
                host.stop(sessionID)
            },
            loadEarlier: transcript.hasEarlier ? { host.loadEarlier(sessionID) } : nil,
            suggestions: suggestions,
            pick: { draft = $0.text }
        ) {
            if let approval = transcript.pendingApproval {
                ApprovalControls(request: approval,
                                 allow: { host.approve(sessionID, id: approval.id, allow: true) },
                                 deny: { host.approve(sessionID, id: approval.id, allow: false) })
            } else if let info {
                // Pictures, before anything else in the row: what you are
                // about to say, then how it is being said.
                // A phone asks where from; a Mac or a browser goes
                // straight to files.
                if Self.offersAttachMenu {
                    Menu {
                        if Self.canTakePhotos {
                            Button("Camera", systemImage: "camera") { attachSource = .camera }
                        }
                        Button("Photo Library", systemImage: "photo.on.rectangle") { attachSource = .library }
                        Button("Files", systemImage: "folder") { attachSource = .files }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .agentSoftCircleButton()
                    .accessibilityLabel("Attach")
                    .accessibilityIdentifier("attach")
                } else {
                    Button { attachSource = .files } label: { Image(systemName: "plus") }
                        .agentSoftCircleButton()
                        .accessibilityLabel("Attach files")
                        .accessibilityIdentifier("attach")
                }
                // The model, as the Claude app's pill: tap to change it or the effort.
                let fallback = host.fallbackModel(for: info)
                Button { showModels = true } label: {
                    // "Opus 5 High": the model, then how hard it is being
                    // asked to think, in grey so the two read apart. After
                    // a fallback, the model the turn ran on, marked.
                    if let fallback {
                        Text(Image(systemName: "arrow.down.circle.fill")).foregroundColor(.orange)
                            + Text(" " + fallback.title)
                            + Text(info.effort.map { " " + AgentCatalog.effortTitle($0) } ?? "")
                                .foregroundColor(.secondary)
                    } else {
                        Text(host.modelTitle(for: info))
                            + Text(info.effort.map { " " + AgentCatalog.effortTitle($0) } ?? "")
                                .foregroundColor(.secondary)
                    }
                }
                .lineLimit(1)
                .agentPillButton()
                .accessibilityLabel(fallback.map { "Model: fell back to \($0.title) from \(host.modelTitle(for: info))" } ?? "Model")
                .accessibilityIdentifier("model")
                // What the agent keeps working toward, or wakes itself for:
                // there for as long as it lasts.
                if let goal = info.goal {
                    // A glyph, not words: the row is a phone's width, and the
                    // model's name needs it more. Tapped, it says what it is.
                    Button { goalShown = goal } label: {
                        Image(systemName: "flag.fill")
                    }
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
                    .agentPillButton()
                    .accessibilityLabel("Goal: " + goal)
                    .accessibilityIdentifier("goal")
                }
                if info.loopWake != nil || info.loopCron != nil {
                    Button { loopShown = true } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
                    .agentPillButton()
                    .accessibilityLabel("Looping")
                    .accessibilityIdentifier("loop")
                }
                // What the user has said while the agent works. It goes
                // over when the turn ends; this is how to jump the queue
                // or think better of it.
                if !info.queued.isEmpty {
                    Menu {
                        Button { host.stop(sessionID) } label: {
                            Label("Send now (interrupts the turn)", systemImage: "forward.end")
                        }
                        Button(role: .destructive) { host.unqueue(sessionID) } label: {
                            Label(info.queued.count == 1 ? "Discard it" : "Discard all \(info.queued.count)", systemImage: "trash")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "clock").font(.caption)
                            AgentPillLabel(info.queued.count == 1 ? "1 queued" : "\(info.queued.count) queued")
                        }
                    }
                    .agentPillButton()
                    .accessibilityLabel("Queued messages")
                    .accessibilityIdentifier("queued")
                }
            }
        } attachments: {
            ForEach(attachments) { picked in
                AgentAttachmentTile(remove: { attachments.removeAll { $0.id == picked.id } }) {
                    if picked.isVideo {
                        // A frame of it, marked as a video.
                        ZStack {
                            if let thumbnail = picked.thumbnail {
                                Base64Image(base64: thumbnail)
                            } else {
                                Color.secondary.opacity(0.15)
                            }
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                                .foregroundColor(.white)
                                .shadow(radius: 2)
                        }
                    } else if AttachmentKind.isImage(picked.name) {
                        Base64Image(base64: picked.base64)
                    } else {
                        // Any other file: what it is called.
                        VStack(spacing: 4) {
                            Image(systemName: "doc").font(.title3).foregroundColor(.secondary)
                            Text(picked.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.secondary.opacity(0.12))
                    }
                }
            }
        }
        .attachmentPickers($attachSource, onPick: attach)
        // Files dropped on the chat are attached, as if picked.
        .attachmentDrop(onPick: attach)
        .alert("Goal", isPresented: Binding(get: { goalShown != nil }, set: { if !$0 { goalShown = nil } })) {
            Button("Clear Goal", role: .destructive) { host.sendMessage(sessionID, text: "/goal clear") }
            Button("OK", role: .cancel) {}
        } message: {
            Text((goalShown ?? "") + "\n\nThe agent keeps working until this is met.")
        }
        .alert("Loop", isPresented: $loopShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(info?.loopCron.map { "The agent runs again on the schedule \($0)." }
                 ?? "The agent has set itself to wake and carry on.")
        }
        .sheet(isPresented: $showModels) {
            if let info { ModelSheet(host: host, session: info) }
        }
        .overlay(alignment: .top) {
            if info?.archived == true {
                Text("Archived — a message resumes it")
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .padding(.top, 6)
            }
        }
    }

    /// The road to the computer, when it is not open: shown where the
    /// turn's status goes, under the thread, rather than floating over it.
    private var connectionStatus: String? {
        switch host.state {
        case .connected: nil
        case .connecting: host.config.everConnected ? "Reconnecting…" : "Connecting…"
        case .offline: "Reconnecting…"
        case .failed(let reason): "Connection failed: \(reason)"
        case .needsPassword: "The computer wants its password — see Computer Settings"
        case .disconnected: "Not connected"
        }
    }

    /// The session as a reader sees it while someone else drives the
    /// agent's terminal: what it has said, and the two ways in.
    private var watching: some View {
        VStack(spacing: 0) {
            TranscriptView(messages: rows,
                           activity: connectionStatus, error: transcript.error,
                           emptyTitle: "Nothing said yet",
                           emptyBody: "The agent's own terminal has this session.",
                           loadEarlier: transcript.hasEarlier ? { host.loadEarlier(sessionID) } : nil)
            Divider()
            VStack(spacing: 10) {
                Label("Being driven from another window", systemImage: "terminal")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button("Take control") { taking = true }
                        .buttonStyle(.borderedProminent)
                    Button("Return to chat") { returning = true }
                        .buttonStyle(.bordered)
                }
                .font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, TranscriptMetrics.edgeInset)
            .padding(.vertical, 12)
        }
        .alert("Take control of the terminal?", isPresented: $taking) {
            Button("Cancel", role: .cancel) {}
            Button("Take control") {
                let cells = TerminalMetrics.cells(in: paneSize)
                host.assumeControl(sessionID, cols: cells.cols, rows: cells.rows)
            }
        } message: {
            Text("The agent's terminal starts again for this window. Whoever is driving it now loses it, and anything half-typed there is lost.")
        }
        .alert("Hand the session back to the chat?", isPresented: $returning) {
            Button("Cancel", role: .cancel) {}
            Button("Return to chat") { host.returnToChat(sessionID) }
        } message: {
            Text("The terminal ends and the session carries on in the chat. Anything half-typed in the terminal is lost.")
        }
    }

    /// The record's rows, each under the id it keeps through its copies.
    /// The record's rows, then what was just sent to an idle agent: in the
    /// thread at once, under the id its copy in the record takes over, so
    /// the row stays where it is when the record catches up.
    private var rows: [TranscriptMessage] {
        transcript.entries.map { TranscriptMessage($0, host: host.id, id: transcript.displayID(of: $0)) }
            + transcript.sending.filter(\.shown).map { TranscriptMessage($0.entry, host: host.id, id: $0.id) }
    }

    /// The session's name, as the sidebar lists it.
    private var sessionTitle: String {
        info.map { $0.title.isEmpty ? $0.agent.title : $0.title } ?? "Session"
    }

    /// Puts what was picked on the computer as it is chosen: by the time
    /// the message goes, the agent already has somewhere to look.
    private func attach(_ picked: [PickedImage]) {
        Task {
            for var file in picked {
                if file.isVideo { file.thumbnail = await VideoThumbnail.png(videoBase64: file.base64, name: file.name) }
                file.path = try? await host.upload(base64: file.base64, name: file.name)
                if file.path != nil { attachments.append(file) }
            }
        }
    }

    private func send() {
        let text = draft.trimmed
        let paths = attachments.compactMap(\.path)
        guard !text.isEmpty || !paths.isEmpty else { return }
        draft = ""
        attachments = []
        // The pictures travel beside the words: the transcript shows them,
        // and the host names their paths to the agent.
        host.sendMessage(sessionID, text: text, images: paths)
    }
}
