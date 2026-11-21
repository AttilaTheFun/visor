import AgentUI
import SwiftUI
import VisorClient
import VisorProtocol

/// Super Compact, from a session's menu (SuperCompact; docs/super-compact.md):
/// the job started on the session's computer and followed (its phase, the
/// map's chunk n of N, the merge, the final step, the check's warnings),
/// cancelled if need be; then HANDOFF.md for the person to review, as
/// markdown, edited if they like, and either started from (a new session
/// carrying the work on, the old one archived) or discarded. Nothing is
/// cut over without this review.
@MainActor
struct SuperCompactSheet: View {
    let compact: SuperCompact
    /// Opens the session it was carried on as.
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    /// The sheet is open: what keeps a running job followed.
    @State private var shown = false
    /// HANDOFF.md being edited, and the edit's words.
    @State private var editing = false
    @State private var draft = ""
    @State private var discarding = false

    /// What the review says above the handoff (NCH's review of #477).
    static let secretsNote = "This summary was written from the session's transcript. It may include secrets that appeared in tool output, "
        + "so check before using it."

    var body: some View {
        NavigationStack {
            Group {
                if editing { editor } else { Form { content }.insetGroupedForm() }
            }
            .navigationTitle(editing ? "Edit HANDOFF.md" : "Super Compact “\(compact.session.title)”")
            .toolbarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .presentationDetentsLarge()
        .task {
            shown = true
            if compact.stage == .loading { await compact.load() }
            await compact.follow { shown }
        }
        // Started here (or carried on): followed from then on.
        .onChange(of: compact.stage) { _, stage in
            if stage == .running { Task { await compact.follow { shown } } }
        }
        .onDisappear { shown = false }
        .alert("Discard this handoff?", isPresented: $discarding) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) { Task { await compact.discard() } }
        } message: {
            Text("Nothing changes: “\(compact.session.title)” carries on as it is. HANDOFF.md stays on \(compact.host.record.name), "
                 + "and a new Super Compact can be started.")
        }
    }

    @ViewBuilder private var content: some View {
        if let problem = compact.problem {
            Section {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .accessibilityIdentifier("super-compact-error")
            }
        }
        switch compact.stage {
        case .loading:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Asking \(compact.host.record.name)…").foregroundStyle(.secondary)
                }
            }
        case .ready: ready
        case .running: running
        case .review, .cuttingOver: review
        case .continued(let next): continued(next)
        }
    }

    // MARK: The stages

    @ViewBuilder private var ready: some View {
        Section {
            Text("A summary of everything that matters in this session — the decisions and rules, the state of each area, the open work — "
                 + "written as HANDOFF.md from its whole conversation, for a new session to carry the work on from.")
            if let last = compact.status, last.phase == .failed {
                Label("The last one failed\(last.error.map { ": \($0)" } ?? "."). Starting again carries it on from where it stopped.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if let last = compact.status, last.phase == .cancelled {
                Text("The last one was cancelled.").foregroundStyle(.secondary)
            } else if compact.status?.discarded == true {
                Text("The last handoff was discarded.").foregroundStyle(.secondary)
            }
            Button {
                Task { await compact.start() }
            } label: {
                Label(compact.status?.phase == .failed ? "Carry On" : "Start", systemImage: "play.fill")
            }
            .disabled(compact.working)
            .accessibilityIdentifier("super-compact-start")
        } footer: {
            Text("It runs on \(compact.host.record.name) — Haiku a chunk at a time, then Sonnet, then Opus — for half an hour to a few hours, "
                 + "one at a time on the computer. The session keeps running meanwhile, and you can close this. You review HANDOFF.md before anything changes.")
        }
    }

    @ViewBuilder private var running: some View {
        if let status = compact.status {
            Section {
                ProgressView(value: status.fraction) { Text(status.progressWords) }
                    .accessibilityIdentifier("super-compact-progress")
                Text(Self.phaseLine(status)).font(.footnote).foregroundStyle(.secondary)
                if let error = status.error {
                    Label("Tried again: \(error)", systemImage: "arrow.clockwise").font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("It runs on \(compact.host.record.name), whether this is open or not: close it, and it's here when you come back.")
            }
            warnings(status.warnings)
            Section {
                Button(role: .destructive) {
                    Task { await compact.cancel() }
                } label: {
                    Label("Cancel Super Compact", systemImage: "xmark.circle")
                }
                .disabled(compact.working)
                .accessibilityIdentifier("super-compact-cancel")
            }
        }
    }

    @ViewBuilder private var review: some View {
        Section {
            Label(Self.secretsNote, systemImage: "key")
                .font(.footnote)
                .accessibilityIdentifier("super-compact-secrets-note")
        }
        warnings(compact.status?.warnings ?? [])
        Section {
            Button {
                Task {
                    if let next = await compact.cutOver() { open(next) }
                }
            } label: {
                Label("Start New Session", systemImage: "arrow.right.circle.fill")
            }
            .disabled(compact.working)
            .accessibilityIdentifier("super-compact-cutover")
            Button {
                draft = compact.handoff
                editing = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(compact.working)
            .accessibilityIdentifier("super-compact-edit")
            Button(role: .destructive) { discarding = true } label: {
                Label("Discard", systemImage: "trash")
            }
            .disabled(compact.working)
            .accessibilityIdentifier("super-compact-discard")
        } footer: {
            Text("Start New Session: a new session, “\(compact.session.title) (continued)”, in a folder of its own, with HANDOFF.md and Claude's memory, "
                 + "the same model and effort, told to read HANDOFF.md first. This one is archived, never deleted, and its mail goes to the new one.")
        }
        if compact.stage == .cuttingOver {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Starting the new session…").foregroundStyle(.secondary)
                }
            }
        }
        Section("HANDOFF.md") {
            ForEach(Array(Self.parts(of: compact.handoff).enumerated()), id: \.offset) { _, part in
                MarkdownText(part)
            }
        }
        .accessibilityIdentifier("super-compact-handoff")
    }

    @ViewBuilder private func continued(_ next: String) -> some View {
        Section {
            Label("Continued as “\(compact.continuedTitle ?? next)”.", systemImage: "checkmark.circle.fill")
                .accessibilityIdentifier("super-compact-continued")
            Text("“\(compact.session.title)” is archived, never deleted, and its mail goes to the new session.")
                .font(.footnote).foregroundStyle(.secondary)
            Button {
                open(next)
                dismiss()
            } label: {
                Label("Open “\(compact.continuedTitle ?? next)”", systemImage: "arrow.right.circle")
            }
            .accessibilityIdentifier("super-compact-open")
        }
    }

    @ViewBuilder private func warnings(_ warnings: [String]) -> some View {
        if !warnings.isEmpty {
            Section("Check") {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .accessibilityIdentifier("super-compact-warnings")
        }
    }

    private var editor: some View {
        TextEditor(text: $draft)
            .padding(.horizontal, 8)
            .accessibilityIdentifier("super-compact-editor")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if editing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { editing = false }.accessibilityIdentifier("super-compact-edit-cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { if await compact.save(draft) { editing = false } }
                }
                .disabled(compact.working)
                .accessibilityIdentifier("super-compact-save")
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.accessibilityIdentifier("super-compact-done")
            }
        }
    }

    // MARK: Words

    /// Where the job is, at a glance.
    static func phaseLine(_ status: SuperCompactStatus) -> String {
        switch status.phase {
        case .prefilter: "Keeping what matters of the conversation: the person's words, the replies, Claude's own summaries."
        case .map: "Haiku summarizes the conversation in order, \(status.chunks) chunks of about 120,000 tokens, carrying the ledger forward."
        case .merge: "Sonnet merges the chunks' ledgers and chapters into one."
        case .final: "Opus writes HANDOFF.md from the merged ledger and timeline."
        case .done, .failed, .cancelled: status.progressWords
        }
    }

    /// HANDOFF.md cut at its headings, each part drawn by itself: a long
    /// one (it may be longer than a context window) is not one huge text.
    static func parts(of markdown: String) -> [String] {
        var parts: [String] = []
        var current: [Substring] = []
        var fenced = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") { fenced.toggle() }
            if !fenced, line.hasPrefix("#"), !current.isEmpty {
                parts.append(current.joined(separator: "\n"))
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        return parts.filter { !AgentText.isBlank($0) }
    }
}
