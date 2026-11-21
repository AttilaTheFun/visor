// Super Compact's steps, each carrying on from what its folder already
// holds:
//
//   chunks/0001.txt …      the prefilter's text (SuperCompactFilter)
//   map/0001.md …          each chunk's ledger and chapter (Haiku)
//   merge/1-0001.md …      each merge's ledger and timeline (Sonnet), by
//                          level, until one is left
//   ledger.md, timeline.md the merged whole
//   HANDOFF.md             the final step's (Opus)
//
// A step's file is written once its answer is whole, so one that is there
// is done; a restart begins at the first that isn't.

import Foundation
import VisorSystem

extension SuperCompaction {
    var folder: URL { job.folderURL }

    func chunkURL(_ index: Int) -> URL {
        folder.appendingPathComponent(SuperCompactFilter.chunksFolder, isDirectory: true)
            .appendingPathComponent(SuperCompactFilter.chunkName(index), isDirectory: false)
    }

    func mapURL(_ index: Int) -> URL {
        folder.appendingPathComponent("map", isDirectory: true).appendingPathComponent(String(format: "%04d.md", index), isDirectory: false)
    }

    func mergeURL(level: Int, index: Int) -> URL {
        folder.appendingPathComponent("merge", isDirectory: true).appendingPathComponent(String(format: "%d-%04d.md", level, index), isDirectory: false)
    }

    var handoffURL: URL { folder.appendingPathComponent("HANDOFF.md", isDirectory: false) }

    /// How many outputs each level of the merge makes, for `count` map
    /// outputs in groups of `group`: down to one, and at least one level.
    static func mergeLevels(count: Int, group: Int) -> [Int] {
        var levels: [Int] = []
        var left = max(count, 1)
        repeat {
            left = (left + group - 1) / group
            levels.append(left)
        } while left > 1
        return levels
    }

    // MARK: The prefilter

    func prefilter() async throws {
        let source = URL(fileURLWithPath: job.source, isDirectory: false)
        let stop = self.stop
        let outcome: SuperCompactFilter.Outcome
        do {
            outcome = try await SuperCompactFilter.run(source: source, limit: job.sourceBytes,
                                                       into: folder.appendingPathComponent(SuperCompactFilter.chunksFolder, isDirectory: true),
                                                       chunkCharacters: job.settings.chunkCharacters, stop: { stop.isSet })
        } catch SuperCompactFilter.Failure.stopped {
            throw Failure.stopped
        } catch SuperCompactFilter.Failure.unreadable(let path) {
            throw Failure.failed("Could not read the conversation at \(path)")
        }
        // Cancelled as it finished: it stays cancelled.
        if stop.isSet { throw Failure.stopped }
        guard outcome.chunks > 0 else { throw Failure.failed("The conversation holds nothing to compact") }
        update {
            $0.chunks = outcome.chunks
            $0.chunk = 0
            $0.filteredCharacters = outcome.characters
            $0.phase = .map
        }
    }

    // MARK: The map

    func map() async throws {
        guard job.chunks > 0 else { throw Failure.failed("The job has no chunks to map") }
        try? FileManager.default.createDirectory(at: mapURL(1).deletingLastPathComponent(), withIntermediateDirectories: true)
        for index in 1...job.chunks {
            let out = mapURL(index)
            if FileManager.default.fileExists(atPath: out.path) {
                if job.chunk < index { update { $0.chunk = index } }
                continue
            }
            guard let chunk = try? String(contentsOf: chunkURL(index), encoding: .utf8) else {
                throw Failure.failed("Chunk \(index) of \(job.chunks) is missing from \(folder.path)")
            }
            var ledger = ""
            if index > 1 { ledger = try part(mapURL(index - 1), SuperCompactPrompts.chapterMarker).ledger }
            let prompt = SuperCompactPrompts.map(chunk: chunk, index: index, count: job.chunks, ledger: ledger)
            let answer = try await ask(job.settings.mapModel, prompt, step: "chunk \(index) of \(job.chunks)") {
                SuperCompactPrompts.parts(of: $0, SuperCompactPrompts.ledgerMarker, SuperCompactPrompts.chapterMarker) != nil
            }
            guard let mapped = SuperCompactPrompts.parts(of: answer, SuperCompactPrompts.ledgerMarker, SuperCompactPrompts.chapterMarker)
            else { throw Failure.failed("chunk \(index) of \(job.chunks): no ledger in the answer") }
            try write(Self.document(mapped.0, SuperCompactPrompts.chapterMarker, mapped.1), to: out)
            update {
                $0.chunk = index
                $0.error = nil
            }
        }
        update {
            $0.mergeSteps = Self.mergeLevels(count: $0.chunks, group: $0.settings.group).reduce(0, +)
            $0.mergeStep = 0
            $0.phase = .merge
        }
    }

    // MARK: The merge

    func merge() async throws {
        guard job.chunks > 0 else { throw Failure.failed("The job has no chunks to merge") }
        try? FileManager.default.createDirectory(at: mergeURL(level: 1, index: 1).deletingLastPathComponent(), withIntermediateDirectories: true)
        let group = job.settings.group
        let levels = Self.mergeLevels(count: job.chunks, group: group)
        let steps = levels.reduce(0, +)
        var inputs = (1...job.chunks).map { (url: mapURL($0), story: SuperCompactPrompts.chapterMarker) }
        var step = 0
        for (offset, size) in levels.enumerated() {
            let level = offset + 1
            var outputs: [(url: URL, story: String)] = []
            for index in 1...size {
                step += 1
                let out = mergeURL(level: level, index: index)
                outputs.append((out, SuperCompactPrompts.timelineMarker))
                if FileManager.default.fileExists(atPath: out.path) { continue }
                let members = inputs[((index - 1) * group)..<min(index * group, inputs.count)]
                let parts = try members.map { try part($0.url, $0.story) }
                let prompt = SuperCompactPrompts.merge(parts: parts.map { (ledger: $0.ledger, story: $0.story) }, level: level, step: step, steps: steps)
                let answer = try await ask(job.settings.mergeModel, prompt, step: "merge \(step) of \(steps)") {
                    SuperCompactPrompts.parts(of: $0, SuperCompactPrompts.ledgerMarker, SuperCompactPrompts.timelineMarker) != nil
                }
                guard let merged = SuperCompactPrompts.parts(of: answer, SuperCompactPrompts.ledgerMarker, SuperCompactPrompts.timelineMarker)
                else { throw Failure.failed("merge \(step) of \(steps): no ledger in the answer") }
                try write(Self.document(merged.0, SuperCompactPrompts.timelineMarker, merged.1), to: out)
                update {
                    $0.mergeStep = step
                    $0.mergeSteps = steps
                    $0.error = nil
                }
            }
            inputs = outputs
        }
        let top = try part(inputs[0].url, SuperCompactPrompts.timelineMarker)
        try write(top.ledger + "\n", to: folder.appendingPathComponent("ledger.md", isDirectory: false))
        try write(top.story + "\n", to: folder.appendingPathComponent("timeline.md", isDirectory: false))
        update {
            $0.mergeStep = steps
            $0.mergeSteps = steps
            $0.phase = .final
        }
    }

    // MARK: The final step, and the check

    func final() async throws {
        guard let ledger = try? String(contentsOf: folder.appendingPathComponent("ledger.md", isDirectory: false), encoding: .utf8),
              let timeline = try? String(contentsOf: folder.appendingPathComponent("timeline.md", isDirectory: false), encoding: .utf8) else {
            throw Failure.failed("The merged ledger and timeline are missing from \(folder.path)")
        }
        let handoff: String
        if let written = try? String(contentsOf: handoffURL, encoding: .utf8) {
            handoff = written
        } else {
            let prompt = SuperCompactPrompts.final(ledger: ledger, timeline: timeline, title: job.title, session: job.session,
                                                   conversation: job.conversation, cwd: cwd)
            let answer = try await ask(job.settings.finalModel, prompt, step: "HANDOFF.md") {
                SuperCompactPrompts.unfenced($0).contains("#")
            }
            handoff = SuperCompactPrompts.unfenced(answer) + "\n"
            try write(handoff, to: handoffURL)
        }
        let warnings = SuperCompactCheck.warnings(ledger: ledger, handoff: handoff)
        let path = handoffURL.path
        update {
            $0.warnings = warnings
            $0.handoff = path
            $0.error = nil
            $0.phase = .done
            $0.finished = Date().timeIntervalSince1970
        }
    }

    // MARK: Files

    /// A step's output: its ledger, then its story (a chapter, or a
    /// timeline) after `marker`.
    static func document(_ ledger: String, _ marker: String, _ story: String) -> String {
        SuperCompactPrompts.ledgerMarker + "\n" + ledger + "\n" + marker + "\n" + story + "\n"
    }

    /// A step's output read back: its ledger and its story.
    func part(_ url: URL, _ marker: String) throws -> (ledger: String, story: String) {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let read = SuperCompactPrompts.parts(of: text, SuperCompactPrompts.ledgerMarker, marker) else {
            throw Failure.failed("Could not read \(url.path)")
        }
        return (read.0, read.1)
    }

    func write(_ text: String, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw Failure.failed("Could not write \(url.path): \(error)")
        }
    }

    // MARK: Calls

    /// The model's answer to `prompt`, tried up to `attempts` times until
    /// one exits well with an answer `usable` takes.
    func ask(_ model: String, _ prompt: String, step: String, usable: (String) -> Bool) async throws -> String {
        var last = ""
        for attempt in 1...max(attempts, 1) {
            if stop.isSet { throw Failure.stopped }
            let outcome = await Self.call(tool: tool, model: model, prompt: prompt, in: folder, limit: callLimit, stop: stop, caller: caller)
            if stop.isSet { throw Failure.stopped }
            switch outcome {
            case .success(let answer) where usable(answer):
                return answer
            case .success(let answer):
                last = "\(step): the answer was not in the form asked for (\(SuperCompactFilter.oneLine(answer, 200)))"
            case .failure(let failure):
                last = "\(step): \(failure.reason)"
            }
            let said = last
            VisorServer.log("super compact \(job.id): attempt \(attempt) failed: \(said)")
            update { $0.error = "attempt \(attempt) failed: \(said)" }
        }
        throw Failure.failed(last)
    }

    /// Why a call gave no answer.
    struct CallFailure: Error {
        let reason: String
    }

    /// The arguments of a call: Claude Code headless on `model`, with no
    /// tools, no MCP servers, no customizations (CLAUDE.md, hooks,
    /// plugins, skills: `--safe-mode`), nothing kept of the session, and
    /// a system prompt of its own; the prompt on standard input, the
    /// answer as JSON.
    nonisolated static func arguments(model: String) -> [String] {
        ["-p", "--model", model, "--output-format", "json", "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
         "--safe-mode", "--disable-slash-commands", "--no-session-persistence", "--system-prompt", SuperCompactPrompts.system]
    }

    /// One call of `claude -p`, in `folder` (or by `caller`: in the
    /// Sessions container), ended when `stop` is set or it has taken
    /// `limit`.
    @concurrent
    static func call(tool: String, model: String, prompt: String, in folder: URL, limit: Duration,
                     stop: Stop, caller: Caller? = nil) async -> Result<String, CallFailure> {
        let deadline = ContinuousClock.now + limit
        let stopping: @Sendable () -> Bool = { stop.isSet || ContinuousClock.now >= deadline }
        let ran: (status: Int32, text: String, stopped: Bool)?
        if let caller {
            ran = await caller(arguments(model: model), Data(prompt.utf8), limit, stopping)
        } else {
            ran = await Command.output(tool, arguments(model: model), environment: ToolPath.environment(), directory: folder, errors: true,
                                       input: Data(prompt.utf8), every: .milliseconds(200), stopping: stopping)
        }
        guard let ran else {
            return .failure(CallFailure(reason: caller == nil ? "could not start \(tool)" : "could not run \(tool) in the Sessions container"))
        }
        if ran.stopped {
            return .failure(CallFailure(reason: stop.isSet ? "stopped" : "took longer than \(limit), and was ended"))
        }
        return answer(ran.text, status: ran.status)
    }

    /// The answer in what `claude -p --output-format json` printed (its
    /// errors among it): the result's text, or why there is none.
    nonisolated static func answer(_ printed: String, status: Int32) -> Result<String, CallFailure> {
        for line in printed.split(separator: "\n").reversed() {
            guard let object = JSON.object(String(line)), object["type"] as? String == "result" else { continue }
            let result = object["result"] as? String ?? ""
            if object["is_error"] as? Bool == true || object["subtype"] as? String != "success" {
                return .failure(CallFailure(reason: "claude said: " + SuperCompactFilter.oneLine(result.isEmpty ? String(line) : result, 300)))
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .failure(CallFailure(reason: "claude answered nothing")) : .success(result)
        }
        let tail = String(printed.suffix(300))
        return .failure(CallFailure(reason: "claude exited \(status) with no result: " + SuperCompactFilter.oneLine(tail, 300)))
    }
}
