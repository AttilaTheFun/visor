// The reply being written, as subscribers are told of it
// (VisorServer+Streams): the agent's pieces gathered per session and told
// five times a second, each message's as one append saying where it goes
// (`from`, a UTF-8 offset); anything else told first tells what streamed
// before it; a snapshot, on subscribing or asked for (`state`), is where
// the next append starts; and a turn beginning lets go of an earlier
// turn's words the record never carried.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import VisorSystem
import Testing

/// What the server wrote to a client's socket.
private final class FrameStream: ByteStream {
    var sent: [Data] = []
    func receive(_ chunk: @escaping @MainActor (Data?) -> Void) {}
    func send(_ data: Data, sent: (@MainActor () -> Void)?) { self.sent.append(data); sent?() }
    func close() {}

    /// The envelopes in the frames sent (unmasked, as a server sends them).
    var envelopes: [Envelope] {
        sent.compactMap { data in
            let bytes = [UInt8](data)
            guard bytes.count >= 2, bytes[0] & 0x0F == 1 else { return nil }
            let length = Int(bytes[1] & 0x7F)
            let start = length == 126 ? 4 : length == 127 ? 10 : 2
            return Envelope.decode(String(decoding: bytes[start...], as: UTF8.self))
        }
    }

    /// The deltas sent: each message's id, where its words go, and the words.
    var deltas: [String] {
        envelopes.filter { $0.type == "delta" }.map { "\($0.id ?? "")@\($0.from.map(String.init) ?? "-"):\($0.text ?? "")" }
    }
}

extension ServerTests {
@Suite @MainActor final class StreamCoalescingTests {
    private var server: VisorServer!

    init() async throws {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-streams-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: ServerTestCase.freePort())
        server.password = "pw"
    }

    isolated deinit {
        server.stop()
    }

    private func record(_ id: String) -> SessionRecord {
        let record = SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: id, created: 0),
                                   process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
        server.sessions.append(record)
        return record
    }

    /// A client signed in and subscribed to `session`, and what it is sent.
    private func subscriber(to session: String) -> (client: ClientConnection, stream: FrameStream) {
        let stream = FrameStream()
        // Its socket opened, as a client's WebSocket opens it.
        let upgrade = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        let client = ClientConnection(stream: stream, received: Data(upgrade.utf8))
        client.start()
        client.authenticated = true
        server.connections[ObjectIdentifier(client)] = client
        server.handle(.subscribe(session: session), from: client)
        return (client, stream)
    }

    /// Waits, up to two seconds, for `done`.
    private func until(_ done: () -> Bool) async {
        for _ in 0..<100 where !done() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func testPiecesAreToldAsOneOffsetAppendPerMessageAtTheFlush() async throws {
        let session = record("A")
        let seen = subscriber(to: "A").stream
        server.handle(.busy(true), from: session)
        let pieces = ["Hel", "lo, ", "wö", "rld ", "🙂"]
        for piece in pieces { server.handle(.delta(message: "M", text: piece), from: session) }
        #expect(seen.deltas.isEmpty, "nothing told before the flush")
        let revision = session.stateRevision
        await until { !seen.deltas.isEmpty }
        #expect(seen.deltas == ["M@0:Hello, wörld 🙂"], "one append, from the start")
        #expect(session.stateRevision == revision + 1, "pollers hear of it once")

        // Where the next go: after the words told, in UTF-8 bytes; a second
        // message after the first, from its own start.
        let told = "Hello, wörld 🙂".utf8.count
        server.handle(.delta(message: "M", text: "!"), from: session)
        server.handle(.delta(message: "N", text: "Next"), from: session)
        server.handle(.delta(message: "M", text: "?"), from: session)
        await until { seen.deltas.count == 3 }
        #expect(seen.deltas == ["M@0:Hello, wörld 🙂", "M@\(told):!?", "N@0:Next"])
        // The record holds every word, and its snapshot says so.
        #expect(session.streams.map(\.text) == ["Hello, wörld 🙂!?", "Next"])
        #expect((session.ephemeralEnvelope.streams?.map(\.text)) == ["Hello, wörld 🙂!?", "Next"])
        #expect(VisorServer.streamFlush == .milliseconds(200))
    }

    @Test func testAnythingElseToldFirstTellsTheWordsBeforeIt() async throws {
        let session = record("A")
        let seen = subscriber(to: "A").stream
        server.handle(.busy(true), from: session)
        server.handle(.delta(message: "M", text: "Let me look"), from: session)
        server.handle(.delta(message: "M", text: " at the tests."), from: session)
        server.handle(.activity("Bash: ls"), from: session)
        // At once, the words first, as the agent said them.
        let order = seen.envelopes.map(\.type).filter { $0 == "delta" || $0 == "activity" }
        #expect(order == ["delta", "activity"])
        #expect(seen.deltas == ["M@0:Let me look at the tests."])
        // The flush that was coming has nothing left to tell.
        try await Task.sleep(for: .milliseconds(400))
        #expect(seen.deltas.count == 1)
        // The turn's end tells the last words before it, too.
        server.handle(.delta(message: "M", text: " Done."), from: session)
        server.handle(.busy(false), from: session)
        let ending = seen.envelopes.map(\.type).filter { $0 == "delta" || $0 == "busy" }
        #expect(ending.suffix(2) == ["delta", "busy"])
        #expect(seen.deltas.last == "M@\("Let me look at the tests.".utf8.count): Done.")
    }

    @Test func testASnapshotIsWhereTheNextAppendStarts() async throws {
        let session = record("A")
        let first = subscriber(to: "A").stream
        server.handle(.busy(true), from: session)
        server.handle(.delta(message: "M", text: "abc"), from: session)
        // A second client subscribes mid-reply: the first is told what
        // streamed, the second gets it in its snapshot, not again.
        let (client, second) = subscriber(to: "A")
        #expect(first.deltas == ["M@0:abc"])
        #expect(second.deltas.isEmpty)
        let snapshot = try #require(second.envelopes.last { $0.type == "ephemeral" })
        #expect(snapshot.streams == [StreamChunk(id: "M", text: "abc")])
        // Both go on from there.
        server.handle(.delta(message: "M", text: "déf"), from: session)
        await until { second.deltas.count == 1 }
        #expect(first.deltas == ["M@0:abc", "M@3:déf"])
        #expect(second.deltas == ["M@3:déf"])
        // A client whose words don't meet `from` asks for the state again:
        // to it alone, after what streamed is told.
        server.handle(.delta(message: "M", text: "g"), from: session)
        server.handle(.state(session: "A"), from: client)
        #expect(second.deltas == ["M@3:déf", "M@7:g"])
        let again = try #require(second.envelopes.last)
        #expect(again.type == "ephemeral")
        #expect(again.streams == [StreamChunk(id: "M", text: "abcdéfg")])
        #expect(first.envelopes.filter { $0.type == "ephemeral" }.count == 1, "the first client's own, on subscribing")
    }

    @Test func testATurnBeginningLetsGoOfAnEarlierTurnsOrphans() throws {
        let session = record("A")
        // An earlier turn's reply the record never carried (cut short, its
        // row lost): in the state while no turn runs.
        session.streams = [(id: "M", text: "Cut short")]
        #expect((session.ephemeralEnvelope.streams?.map(\.id)) == ["M"])
        server.handle(.busy(true), from: session)
        #expect(session.streams.isEmpty)
        #expect((session.ephemeralEnvelope.streams ?? []).isEmpty)
        // The new turn's words stand, and the turn said again (a client's
        // send marks it busy before the agent does) keeps them.
        server.handle(.delta(message: "N", text: "Again"), from: session)
        server.handle(.busy(true), from: session)
        #expect(session.streams.map(\.id) == ["N"])
        #expect(!session.unsent.isEmpty, "still to be told")
    }

    @Test func testAppendsStartOverWhenTheirStreamDid() {
        var appends = StreamAppends()
        appends.add(id: "M", from: 0, text: "ab")
        appends.add(id: "M", from: 2, text: "c")
        appends.add(id: "N", from: 0, text: "x")
        // The stream was cleared and began again: its append starts over.
        appends.add(id: "M", from: 0, text: "new")
        let taken = appends.take()
        #expect(taken == [.init(id: "N", from: 0, text: "x"), .init(id: "M", from: 0, text: "new")])
        #expect(appends.isEmpty)
    }
}
}
