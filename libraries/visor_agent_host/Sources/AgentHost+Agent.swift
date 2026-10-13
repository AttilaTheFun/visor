// The agent: started on pipes, its output cut into numbered lines and
// kept, its errors and its end passed on.

import AgentHostWire
import CVisorPOSIX
import Foundation

extension AgentHost {
    func start() {
        let argv = ([options.executable] + options.arguments).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pipes: [Int32] = [-1, -1, -1]
        let pid = visor_spawn_piped(options.executable, argv, envp, options.directory, &pipes)
        guard pid > 0 else {
            let problem = String(cString: strerror(errno))
            heldErrors.append(Data("Could not start \(options.executable): \(problem)\n".utf8))
            ended = (127, false)
            outputDone = true
            return
        }
        agent = pid
        log("started \(options.executable) as \(pid)")
        input = Outlet(pipes[0], label: "visor.host.input")
        let output = pipes[1], errors = pipes[2]
        Task {
            for await chunk in chunks(of: output) { self.takeOutput(chunk) }
            self.outputEnded()
        }
        Task {
            for await chunk in chunks(of: errors) { self.takeErrors(chunk) }
        }
        Task {
            let end = await ending(of: pid)
            self.agentEnded(end)
        }
    }

    /// Output, cut at its newlines; what follows the last is the start of
    /// the next line.
    func takeOutput(_ chunk: Data) {
        var rest = chunk[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            partial.append(rest[rest.startIndex..<newline])
            take(line: partial)
            partial = Data()
            rest = rest[(newline + 1)...]
        }
        partial.append(rest)
    }

    private func take(line: Data) {
        let number = kept.append(line)
        if attached { server?.write(AgentHostFrame.line(number, line).encoded) }
    }

    func takeErrors(_ chunk: Data) {
        if attached {
            server?.write(AgentHostFrame.errors(chunk).encoded)
        } else {
            heldErrors.append(chunk)
            if heldErrors.count > Self.heldErrorBytes { heldErrors = Data(heldErrors.suffix(Self.heldErrorBytes)) }
        }
    }

    func outputEnded() {
        if !partial.isEmpty {
            take(line: partial)
            partial = Data()
        }
        outputDone = true
        tellEnd()
    }

    func agentEnded(_ end: (status: Int32, signaled: Bool)) {
        log("agent ended: \(end.signaled ? "signal" : "status") \(end.status)")
        ended = end
        input?.closeNow()
        input = nil
        // Something the agent started may hold its output open after it
        // has gone; that is not waited on for long.
        Task {
            try? await Task.sleep(for: .seconds(2))
            if !self.outputDone {
                self.outputDone = true
                self.tellEnd()
            }
        }
        tellEnd()
    }

    /// Tells the server the agent has gone, once its output is all said.
    func tellEnd() {
        guard let ended, outputDone, attached, !exitTold else { return }
        exitTold = true
        server?.write(AgentHostFrame.exited(status: ended.status, signaled: ended.signaled).encoded)
    }
}
