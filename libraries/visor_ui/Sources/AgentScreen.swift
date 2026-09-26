// A session's page: AgentUI's AgentView over the transcript the host
// streams. The composer's pills name the agent and switch its permission
// mode (auto: no prompts; manual: the agent's guarded mode); Stop
// interrupts the turn on the host.

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
    /// Pictures chosen for the next message, already on the computer.
    @State private var attachments: [PickedImage] = []
    @State private var picking = false
    @State private var taking = false
    @State private var returning = false
    @State private var showInspector = false
    /// The room a terminal would have here, in points: what the window is
    /// worth in cells when this client takes control.
    @State private var paneSize: CGSize = .zero
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(host: HostConnection, sessionID: String) {
        self._host = ObservedObject(wrappedValue: host)
        self.sessionID = sessionID
        self._transcript = ObservedObject(wrappedValue: host.transcript(for: sessionID))
    }

    private var info: SessionInfo? { host.sessions.first { $0.id == sessionID } }

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
            .onChange(of: geometry.size) { size in paneSize = size }
            .onAppear { paneSize = geometry.size }
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
                                 end: { showInspector = false; host.end(sessionID) })
            }
        }
        .navigationTitle(sessionTitle)
        // The terminal is black; a bar drawn over it keeps its title
        // legible only in the dark palette.
        .terminalBarScheme(controlsTerminal)
        .toolbarTitleDisplayMode(.inline)
        .onAppear { host.subscribe(sessionID) }
        // Whatever changed the mode, the inspector does not outlive the
        // screen it was opened over.
        .onChange(of: info?.mode) { _ in showInspector = false }
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
            sending: !transcript.sending.isEmpty,
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
            loadEarlier: transcript.hasEarlier ? { host.loadEarlier(sessionID) } : nil
        ) {
            if let approval = transcript.pendingApproval {
                ApprovalControls(request: approval,
                                 allow: { host.approve(sessionID, id: approval.id, allow: true) },
                                 deny: { host.approve(sessionID, id: approval.id, allow: false) })
            } else if let info {
                // Pictures, before anything else in the row: what you are
                // about to say, then how it is being said.
                if Self.canPickImages {
                    Button { picking = true } label: { Image(systemName: "plus") }
                        .agentSoftCircleButton()
                        .accessibilityLabel("Attach an image")
                        .accessibilityIdentifier("attach")
                }
                // The model, as the Claude app's pill: tap to change it or the effort.
                Button { showModels = true } label: {
                    // "Opus 5 High": the model, then how hard it is being
                    // asked to think, in grey so the two read apart.
                    Text(host.modelTitle(for: info))
                        + Text(info.effort.map { " " + AgentCatalog.effortTitle($0) } ?? "")
                            .foregroundColor(.secondary)
                }
                .lineLimit(1)
                .agentPillButton()
                .accessibilityLabel("Model")
                .accessibilityIdentifier("model")
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
                    } else {
                        Base64Image(base64: picked.base64)
                    }
                }
            }
        }
        .imagePicker(isPresented: $picking) { picked in
            // Put on the computer as they are chosen: by the time the
            // message goes, the agent already has somewhere to look.
            Task {
                for var image in picked {
                    image.path = try? await host.upload(base64: image.base64, name: image.name)
                    if image.path != nil { attachments.append(image) }
                }
            }
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
        case .offline: "Offline — reconnecting…"
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
    private var rows: [TranscriptMessage] {
        transcript.entries.map { TranscriptMessage($0, host: host.id, id: transcript.displayID(of: $0)) }
    }

    /// The session's name, as the sidebar lists it.
    private var sessionTitle: String {
        info.map { $0.title.isEmpty ? $0.agent.title : $0.title } ?? "Session"
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

/// In the composer while a tool call waits: what it is, Allow, Deny.
@MainActor
struct ApprovalControls: View {
    let request: ApprovalRequest
    let allow: () -> Void
    let deny: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundColor(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.tool).font(.subheadline.weight(.medium))
                if !request.summary.isEmpty {
                    Text(request.summary).font(.caption.monospaced()).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Deny", action: deny).agentPillButton().accessibilityIdentifier("deny")
            Button("Allow", action: allow).agentPillButton().foregroundColor(.green).accessibilityIdentifier("allow")
        }
    }
}

extension TranscriptMessage {
    /// `host` because a picture is a file on that computer: the reference
    /// carries which one, so the transcript's image hook knows where to ask.
    /// `id`: the id to show it under (the transcript's display id), when
    /// not the row's own.
    init(_ entry: TranscriptEntry, host: String = "", id: String? = nil) {
        let role: TranscriptMessage.Role
        switch entry.role {
        case .user: role = .user
        case .assistant: role = .assistant
        case .tool: role = .tool
        }
        // Pictures are shown; a video is named under the words, as the
        // transcript has no player.
        let pictures = entry.images.indices.filter { !AttachmentKind.isVideo(entry.images[$0]) }
        let videos = entry.images.filter(AttachmentKind.isVideo).map { "Video: " + ($0 as NSString).lastPathComponent }
        let text = ([entry.text] + videos).filter { !$0.isEmpty }.joined(separator: "\n")
        self.init(id: id ?? entry.id, role: role, text: text, activities: entry.activities, toolName: entry.toolName,
                  imageURLs: pictures.map { host + "|" + entry.images[$0] },
                  imageSizes: pictures.map { index in
                      index < entry.imageSizes.count
                          ? CGSize(width: CGFloat(entry.imageSizes[index].width), height: CGFloat(entry.imageSizes[index].height))
                          : nil
                  })
    }
}

extension View {
    /// Dark bar chrome over the terminal, plain chrome everywhere else.
    /// An extension, not a ViewModifier: the portable SwiftUI has none.
    @ViewBuilder func terminalBarScheme(_ active: Bool) -> some View {
        #if os(iOS)
        toolbarColorScheme(active ? .dark : nil, for: .navigationBar)
        #else
        self
        #endif
    }
}
