// What Super Compact asks each tier of its cascade (docs/super-compact.md):
// the map (Haiku) a chunk at a time with the ledger so far, the merge
// (Sonnet) a group of parts at a time, and the final step (Opus) for
// HANDOFF.md. Each prompt goes on the model's standard input and begins
// with a line naming its step, which the tests' fake `claude` reads.

import Foundation

enum SuperCompactPrompts {
    /// The ledger's sections, in order: what the map keeps and carries
    /// forward, and the merge consolidates.
    static let ledgerSections = [
        "Rules and decisions", "Standing preferences", "Who's who", "Current state", "Open work and promises",
        "Waiting on others", "Gotchas and lessons", "Identifiers",
    ]

    /// The markers that divide an answer into its parts.
    static let ledgerMarker = "=== LEDGER ==="
    static let chapterMarker = "=== CHAPTER ==="
    static let timelineMarker = "=== TIMELINE ==="

    /// The system prompt every call runs with, in place of Claude Code's.
    static let system = """
        You condense the transcript of a long working session between a person and an AI agent into notes that let a \
        new agent carry on the work without the transcript. You have no tools: answer with text alone, in exactly the \
        form asked for. Be faithful: never invent anything the transcript does not say, keep identifiers exact, and \
        keep the person's rules and decisions in their own words.
        """

    static let legend = """
        The transcript is prefiltered: each entry begins with its time, [YYYY-MM-DD HH:MM] in UTC. PERSON: the \
        person's own words (the most important). AGENT: the agent's replies. CLAUDE'S COMPACTION SUMMARY: Claude \
        Code's own dense summary of everything before it, which anchors the chronology. TOOL <name>: a tool call with \
        its key arguments; "→" lines are the start of its result. MAIL FROM/TO: messages between agent sessions, as \
        one line. TASK NOTIFICATION: a background task ended. Images, thinking, system reminders and long outputs \
        were dropped.
        """

    static var ledgerForm: String {
        """
        The ledger has exactly these sections, as markdown headings, in this order:
        \(ledgerSections.map { "## " + $0 }.joined(separator: "\n"))

        - Rules and decisions: every rule, decision and standing instruction the person gave, one bullet each, as \
        "- [YYYY-MM-DD] …", quoting the person's words verbatim where the wording matters. Never drop one unless the \
        person withdrew or replaced it: then say so, with the date.
        - Standing preferences: how the person likes things done (style, tone, process).
        - Who's who: the people, agent sessions (names and ids), computers and services, and each one's role.
        - Current state: per area (each repository, release, machine, service): where it stands now. Later news \
        replaces earlier.
        - Open work and promises: what is unfinished or was promised, most important first; remove what got done.
        - Waiting on others: what is blocked on someone or something else, and on whom.
        - Gotchas and lessons: what went wrong, why, and what to do instead.
        - Identifiers: PR and issue numbers, versions, branches, paths, run ids, session ids, URLs that matter.
        """
    }

    /// The map's prompt for chunk `index` of `count` (from 1), carrying
    /// `ledger`, the one the last chunk left (empty for the first).
    static func map(chunk: String, index: Int, count: Int, ledger: String) -> String {
        """
        SUPER COMPACT MAP, CHUNK \(index) OF \(count)

        You are reading a long session's transcript in chronological chunks. With each chunk you get the LEDGER so far \
        (what earlier chunks established) and return it updated, together with a CHAPTER: a summary of this chunk alone.

        \(legend)

        \(ledgerForm)

        Keep the ledger whole (it replaces the one you were given) and under about 15,000 words: compress settled \
        history before dropping anything, and never drop a rule or decision.

        The chapter begins with a heading "## <first date> – <last date>: <a short title>" and tells what happened \
        in this chunk, in order, with dates: what the person asked and decided, what was done and with what result \
        (name PRs, versions, files), what failed and why, and what was left open. Be dense; a few hundred to a \
        couple of thousand words.

        Answer with exactly two parts and nothing before or after them:
        \(ledgerMarker)
        <the whole updated ledger>
        \(chapterMarker)
        <the chapter>

        THE LEDGER SO FAR:
        \(ledger.isEmpty ? "(none yet: this is the first chunk)" : ledger)

        CHUNK \(index) OF \(count) OF THE TRANSCRIPT:
        \(chunk)
        """
    }

    /// The merge's prompt for `parts` (each a ledger and its chapters or
    /// timeline, in order), at `level`, step `step` of `steps`.
    static func merge(parts: [(ledger: String, story: String)], level: Int, step: Int, steps: Int) -> String {
        let given = parts.enumerated().map { index, part in
            """
            ----- PART \(index + 1) OF \(parts.count) -----
            \(ledgerMarker)
            \(part.ledger)
            \(timelineMarker)
            \(part.story)
            """
        }.joined(separator: "\n\n")
        return """
            SUPER COMPACT MERGE, LEVEL \(level), STEP \(step) OF \(steps)

            Below are \(parts.count) consecutive parts of a long session's summary, oldest first. Each has a LEDGER \
            (the state of things as of the end of that part) and a TIMELINE (what happened in it, dated). Merge them \
            into one LEDGER and one TIMELINE for the whole span.

            \(ledgerForm)

            Merging: take the union of the rules and decisions (a later one that replaces an earlier one says so, \
            with both dates); for current state, open work and waiting on others, the latest part wins, but keep \
            what an earlier part has that a later one only forgot; merge who's who, gotchas and identifiers without \
            repeats. Keep the ledger under about 20,000 words.

            The timeline keeps every part's chapters in order, each as "## <dates>: <title>" and a condensed account \
            (keep the dates, decisions, outcomes and identifiers; drop the play-by-play).

            Answer with exactly two parts and nothing before or after them:
            \(ledgerMarker)
            <the merged ledger>
            \(timelineMarker)
            <the merged timeline>

            \(given)
            """
    }

    /// The final step's prompt: HANDOFF.md from the merged `ledger` and
    /// `timeline` of the session `title` (`session`, Claude's
    /// `conversation`), in `cwd`.
    static func final(ledger: String, timeline: String, title: String, session: String, conversation: String, cwd: String) -> String {
        """
        SUPER COMPACT FINAL

        Write HANDOFF.md: the document a new agent reads, in full and before anything else, to continue the session \
        "\(title)" (Visor session \(session), Claude conversation \(conversation), working in \(cwd)) without its \
        transcript. It replaces the transcript, so it must hold everything the new agent needs; it may be long.

        Use exactly these sections, as markdown, in this order:
        # Handoff: \(title)
        (one paragraph: what this session is for, and where things stand)
        ## Who's who
        (people, agent sessions with their ids, computers, services, and each one's role)
        ## Rules and decisions
        (every one in the ledger, dated, the person's words verbatim where it matters; the new agent treats them as \
        the person's own. Leave none out.)
        ## Current state
        (per area: each repository, release, machine, service)
        ## Open work
        (prioritised, most important first, with what is needed to finish each)
        ## Waiting on others
        ## Gotchas
        ## Timeline
        (the chapters, dated, condensed)
        ## Pointers
        (PRs, issues, docs, files, paths and ids to look at)

        Answer with the markdown of HANDOFF.md alone.

        \(ledgerMarker)
        \(ledger)

        \(timelineMarker)
        \(timeline)
        """
    }

    /// An answer's two parts, after `first` and `second`, each trimmed:
    /// nil when the answer lacks either marker or the first part is empty.
    static func parts(of answer: String, _ first: String, _ second: String) -> (String, String)? {
        let text = unfenced(answer)
        guard let open = text.range(of: first), let middle = text.range(of: second, range: open.upperBound..<text.endIndex) else { return nil }
        let one = text[open.upperBound..<middle.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let two = text[middle.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return one.isEmpty ? nil : (one, two)
    }

    /// Without a code fence around the whole of it, as a model may wrap an
    /// answer in.
    static func unfenced(_ answer: String) -> String {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 else { return text }
        text = String(text.dropLast(3))
        if let firstLine = text.firstIndex(of: "\n") { text = String(text[text.index(after: firstLine)...]) } else { text = "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
