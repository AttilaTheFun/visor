// The server's side of the socket: a connection is greeted with what the
// host has, sent the lines it asks for, and then each as it comes; what it
// asks of the agent is done. A newer connection takes over from an older
// one (a server restarted while its last connection was still open).

import AgentHostWire
import CVisorPOSIX
import Foundation

extension AgentHost {
    func connect(_ descriptor: Int32) {
        server?.shutdown()
        connection += 1
        let id = connection
        let outlet = Outlet(descriptor, label: "visor.host.server")
        server = outlet
        attached = false
        lastHere = Date()
        let told = ended.flatMap { outputDone ? $0 : nil }
        outlet.write(AgentHostFrame.hello(AgentHostHello(host: getpid(), agent: agent, oldest: kept.oldest, next: kept.next,
                                                         status: told?.status, signaled: told?.signaled)).encoded)
        Task {
            var reader = AgentHostFrameReader()
            for await chunk in chunks(of: descriptor, closing: outlet) {
                guard let frames = reader.take(chunk) else {
                    outlet.shutdown()
                    continue
                }
                for frame in frames where id == self.connection { self.take(frame) }
            }
            self.disconnected(id)
        }
    }

    private func take(_ frame: AgentHostFrame) {
        switch frame {
        case .attach(let from): attach(from: from)
        case .input(let data): input?.write(data)
        case .closeInput:
            input?.close()
            input = nil
        case .signal(.terminate):
            if agent > 0, ended == nil { kill(agent, SIGTERM) }
        case .signal(.kill):
            killEverything()
        case .limit(let bytes): limit = bytes
        case .release:
            if ended != nil { finish() }
        case .hello, .line, .errors, .exited, .notice, .memory:
            break
        }
    }

    /// What the server missed, then what was held for it, then live.
    private func attach(from: UInt64) {
        guard let server else { return }
        for line in kept.lines(from: from) { server.write(AgentHostFrame.line(line.number, line.text).encoded) }
        if !heldErrors.isEmpty {
            server.write(AgentHostFrame.errors(heldErrors).encoded)
            heldErrors = Data()
        }
        for notice in heldNotices { server.write(AgentHostFrame.notice(notice).encoded) }
        heldNotices = []
        attached = true
        exitTold = false
        lastMemory = 0
        tellEnd()
    }

    private func disconnected(_ id: Int) {
        guard id == connection else { return }
        server = nil
        attached = false
        lastHere = Date()
        // A server that heard the agent go has what it needs.
        if exitTold { finish() }
    }

    /// The agent and everything it started, with no choice.
    private func killEverything() {
        guard agent > 0, ended == nil else { return }
        for member in ProcessTree(root: agent).members { kill(member.pid, SIGKILL) }
        kill(-agent, SIGKILL)
    }

    /// Something the session is told; held while no server is here.
    func tell(_ notice: String) {
        log(notice)
        if attached {
            server?.write(AgentHostFrame.notice(notice).encoded)
        } else {
            heldNotices.append(notice)
        }
    }
}
