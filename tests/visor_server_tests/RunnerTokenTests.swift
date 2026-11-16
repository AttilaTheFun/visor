// A runner's own token on agent_protocol's Claim (RunnerTokens): minted for
// one runner name over REST by the computer's owner, never an agent; a
// claim must show its runner's once the server requires them
// (`runnerTokensRequired`), and a wrong one, or another runner's, is
// refused either way; a renewal or a release showing a runner token beside
// its agent's must show the claim's runner's; and Visor's own native
// runner, given one at its start, claims with them required.

import AgentProtocol
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import VisorDriver
import VisorNativeRunner
import VisorProtocol
@testable import VisorServer
import Testing

/// What a call shows: each token as a bearer, in order.
private func bearers(_ tokens: String...) -> Metadata {
    var metadata = Metadata()
    for token in tokens { metadata.addString("Bearer \(token)", forKey: "authorization") }
    return metadata
}

/// `value` once it is there, within five seconds.
@MainActor
private func eventually<T>(_ value: () -> T?) async -> T? {
    for _ in 0..<500 {
        if let found = value() { return found }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

extension ServerTests {
@Suite(.serialized) @MainActor final class RunnerTokenTests {
    private var server: VisorServer!
    private var listening: VisorDriver.Listening!
    private var root: URL!
    private let port = Int(ServerTestCase.freePort())

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-runner-tokens-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: UInt16(ServerTestCase.freePort()))
        server.password = "pw"
        listening = VisorDriver.Listening(host: "127.0.0.1", port: port, url: "http://127.0.0.1:\(port)", harness: "echo")
        listening.serve(server)
        // Listening once a claim is answered (none required yet).
        for _ in 0..<200 {
            if await code(claimingAs: "Warm-up", bearers()) == nil { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    isolated deinit {
        listening.stop()
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private var jobs: JobQueue { listening.jobs! }

    private func queue(_ title: String) throws -> String {
        var e = Envelope(type: "job")
        e.agent = .claude
        e.title = title
        e.cwd = "/tmp"
        return try jobs.queueStart(e).get()
    }

    private func dispatcher<T: Sendable>(_ body: @escaping @Sendable (AgentProtocol_V1_AgentDispatcher.Client<HTTP2ClientTransport.Posix>) async throws -> T)
        async throws -> T {
        let transport = try HTTP2ClientTransport.Posix(target: .dns(host: "127.0.0.1", port: port), transportSecurity: .plaintext)
        return try await withGRPCClient(transport: transport) { client in
            try await body(AgentProtocol_V1_AgentDispatcher.Client(wrapping: client))
        }
    }

    /// The job a claim as `runner` showing `metadata` is given, if any.
    private func claim(as runner: String, _ metadata: Metadata) async throws -> AgentProtocol_V1_Job? {
        let answer = try await dispatcher { try await $0.claim(.with { $0.runner = runner; $0.capabilities = ["native", "harness:echo"] },
                                                               metadata: metadata) }
        return answer.hasJob ? answer.job : nil
    }

    /// How a call ended: nil when it was answered.
    private func code<T: Sendable>(_ call: @escaping @Sendable (AgentProtocol_V1_AgentDispatcher.Client<HTTP2ClientTransport.Posix>) async throws -> T)
        async -> RPCError.Code? {
        do {
            _ = try await dispatcher(call)
            return nil
        } catch {
            return (error as? RPCError)?.code ?? .unknown
        }
    }

    /// How a claim as `runner` showing `metadata` ended: nil when answered.
    private func code(claimingAs runner: String, _ metadata: Metadata) async -> RPCError.Code? {
        await code { try await $0.claim(.with { $0.runner = runner; $0.capabilities = ["native", "harness:echo"] }, metadata: metadata) }
    }

    private func rest(_ method: String, _ path: String, bearer: String? = "pw", body: String = "", trusted: Bool = false) -> HTTPResponse {
        server.route(HTTPRequest(method: method, path: path, headers: bearer.map { ["authorization": "Bearer " + $0] } ?? [:], body: body,
                                 trusted: trusted))
    }

    /// A token minted over REST for `runner`.
    private func mint(_ runner: String) throws -> String {
        let made = rest("POST", "/api/runners/tokens", body: #"{"runner":"\#(runner)"}"#)
        #expect(made.status == 200)
        return try #require(parseJSON(made.body)?["token"].string)
    }

    private var waiting: [String] { jobs.waiting.map(\.agent.uuid) }

    @Test func aClaimIsRefusedWithoutItsRunnersTokenWhenRequired() async throws {
        let token = try mint("container@mini")
        #expect(rest("PUT", "/api/runners/tokens", body: #"{"required":true}"#).status == 200)
        #expect(server.settings.runnerTokensRequired)
        let id = try queue("A")

        #expect(await code(claimingAs: "container@mini", bearers()) == .unauthenticated, "none shown")
        #expect(await code(claimingAs: "container@mini", bearers("not-a-token")) == .unauthenticated, "a wrong one")
        #expect(await code(claimingAs: "elsewhere", bearers(token)) == .permissionDenied, "another runner's")
        #expect(waiting == [id], "nothing given out")

        let job = try #require(try await claim(as: "container@mini", bearers(token)), "its own, as its name")
        #expect(job.agent.uuid == id)
        #expect(jobs.holder(of: id) == "container@mini")
    }

    @Test func notRequiredAMissingTokenIsLetInButAWrongOneIsNot() async throws {
        #expect(!server.settings.runnerTokensRequired, "off until runners send one")
        let token = try mint("container@mini")
        let id = try queue("A")
        #expect(await code(claimingAs: "container@mini", bearers("not-a-token")) == .unauthenticated)
        #expect(await code(claimingAs: "other@mini", bearers(token)) == .permissionDenied)
        #expect(waiting == [id])
        let job = try #require(try await claim(as: "old-runner", bearers()), "none shown: let in")
        #expect(job.agent.uuid == id)
        // Twice: logged once, let in both times.
        _ = try queue("B")
        #expect(try await claim(as: "old-runner", bearers()) != nil)
    }

    @Test func aRenewalOrReleaseShowingARunnerTokenMustShowTheClaimsRunners() async throws {
        let a = try mint("runner-a")
        let b = try mint("runner-b")
        #expect(rest("PUT", "/api/runners/tokens", body: #"{"required":true}"#).status == 200)
        _ = try queue("A")
        let job = try #require(try await claim(as: "runner-a", bearers(a)))
        let renewal = AgentProtocol_V1_RenewRequest.with { $0.agent = job.agent }

        #expect(await code { try await $0.renew(renewal, metadata: bearers(job.token)) } == nil, "the agent's alone, as before")
        #expect(await code { try await $0.renew(renewal, metadata: bearers(job.token, a)) } == nil, "with its runner's beside it")
        #expect(await code { try await $0.renew(renewal, metadata: bearers(a, job.token)) } == nil, "in either order")
        #expect(await code { try await $0.renew(renewal, metadata: bearers(job.token, b)) } == .permissionDenied, "another runner's")
        #expect(await code { try await $0.renew(renewal, metadata: bearers(a)) } == .unauthenticated, "the runner's is no agent's")

        let released = AgentProtocol_V1_JobReport.with { $0.agent = job.agent; $0.released = .with { $0.reason = "test" } }
        #expect(await code { try await $0.report(released, metadata: bearers(job.token, b)) } == .permissionDenied)
        #expect(jobs.holder(of: job.agent.uuid) == "runner-a", "still held")
        #expect(await code { try await $0.report(released, metadata: bearers(job.token, a)) } == nil)
        #expect(waiting == [job.agent.uuid], "released, queued again")
    }

    @Test func runnerTokensAreMintedListedAndRevokedOverREST() async throws {
        let made = rest("POST", "/api/runners/tokens", body: #"{"runner":"container@mini"}"#)
        #expect(made.status == 200)
        let answer = try #require(parseJSON(made.body))
        let token = try #require(answer["token"].string)
        #expect(answer["runner"].string == "container@mini")
        #expect(token.count == 64 && token.allSatisfy(\.isHexDigit))
        #expect(answer["replaced"].bool == false)
        #expect(!(answer["created"].string ?? "").isEmpty)

        let listed = rest("GET", "/api/runners/tokens")
        #expect(listed.status == 200)
        #expect(!listed.body.contains(token), "names, never tokens")
        let runners = try #require(parseJSON(listed.body)?["runners"].array)
        #expect(runners.map { $0["runner"].string } == ["container@mini"])
        #expect(parseJSON(listed.body)?["required"].bool == false)

        // Kept with the secrets, nowhere else.
        #expect(VisorServer.secrets.get(RunnerTokens.key)?.contains(token) == true)
        _ = try queue("A")
        jobs.save()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            #expect(!text.contains(token), "not in \(file.lastPathComponent)")
        }

        // A server started again reads it back.
        #expect(RunnerTokens(secrets: VisorServer.secrets).runner(presenting: token) == "container@mini")

        #expect(rest("POST", "/api/runners/tokens", body: #"{"runner":""}"#).status == 400)
        #expect(rest("POST", "/api/runners/tokens", body: #"{"runner":"a/b"}"#).status == 400)
        #expect(rest("PUT", "/api/runners/tokens", body: #"{"required":"yes"}"#).status == 400)

        // Minted again: a new one, the old no longer good.
        let again = try #require(parseJSON(rest("POST", "/api/runners/tokens", body: #"{"runner":"container@mini"}"#).body))
        #expect(again["replaced"].bool == true)
        let second = try #require(again["token"].string)
        #expect(second != token)
        #expect(await code(claimingAs: "container@mini", bearers(token)) == .unauthenticated)
        #expect(await code(claimingAs: "container@mini", bearers(second)) == nil)

        // Revoked: refused, gone from the list, and a second revoke is a 404.
        let revoked = rest("DELETE", "/api/runners/tokens/container%40mini")
        #expect(revoked.status == 200)
        #expect(parseJSON(revoked.body)?["runner"].string == "container@mini")
        #expect(await code(claimingAs: "container@mini", bearers(second)) == .unauthenticated)
        #expect(parseJSON(rest("GET", "/api/runners/tokens").body)?["runners"].array?.isEmpty == true)
        #expect(rest("DELETE", "/api/runners/tokens/container@mini").status == 404)
        #expect(VisorServer.secrets.get(RunnerTokens.key) == nil)

        // The switch, kept in the settings.
        #expect(parseJSON(rest("PUT", "/api/runners/tokens", body: #"{"required":true}"#).body)?["required"].bool == true)
        #expect(ServerSettings.kept(at: VisorServer.settingsURL).runnerTokensRequired)
        #expect(parseJSON(rest("PUT", "/api/runners/tokens", body: #"{"required":false}"#).body)?["required"].bool == false)
    }

    @Test func agentsCannotSeeOrChangeRunnerTokens() async throws {
        let token = try mint("container@mini")
        _ = try queue("A")
        let job = try #require(try await claim(as: "container@mini", bearers(token)))
        let calls: [(String, String, String)] = [("GET", "/api/runners/tokens", ""),
                                                 ("POST", "/api/runners/tokens", #"{"runner":"mine"}"#),
                                                 ("PUT", "/api/runners/tokens", #"{"required":false}"#),
                                                 ("DELETE", "/api/runners/tokens/container@mini", "")]
        for (method, path, body) in calls {
            #expect(rest(method, path, bearer: server.agentToken, body: body).status == 403, "the agents' token: \(method)")
            #expect(rest(method, path, bearer: job.token, body: body).status == 401, "a runner's agent's token is never REST's: \(method)")
            #expect(rest(method, path, bearer: token, body: body).status == 401, "nor a runner's own: \(method)")
        }
        #expect(server.runnerTokens.listed.map(\.runner) == ["container@mini"], "nothing minted or revoked")
        #expect(rest("GET", "/api/runners/tokens", bearer: nil, trusted: true).status == 200, "a trusted connection, as the password")
    }

    @Test func theNativeRunnerClaimsWithRunnerTokensRequired() async throws {
        server.settings.runnerTokensRequired = true
        let id = try queue("Native")
        let url = "http://127.0.0.1:\(port)"
        // A wrapper that runs a while: a runner with room for one claims no
        // more meanwhile, so it is stopped with no call in flight.
        let wrapper = root.appendingPathComponent("wrapper.sh").path
        try "#!/bin/sh\nexec sleep 5\n".write(toFile: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)

        // Without a token of its own, it is given nothing.
        let made = NativeRunner(dispatcher: url, wrapper: wrapper, name: "Native", capacity: 1, harnesses: ["echo"], log: { _ in })
        let tokenless = try #require(made)
        let refused = Task { await tokenless.run() }
        try await Task.sleep(for: .milliseconds(1500))
        refused.cancel()
        await refused.value
        #expect(waiting == [id], "refused: still waiting")

        // With the one the server gives its own runner at its start, it is.
        let own = try #require(listening.runnerToken(for: "Native"))
        #expect(server.runnerTokens.listed.contains { $0.runner == "Native" && $0.own })
        let given = NativeRunner(dispatcher: url, wrapper: wrapper, name: "Native", token: own, capacity: 1, harnesses: ["echo"], log: { _ in })
        let runner = try #require(given)
        let running = Task { await runner.run() }
        #expect(await eventually { self.jobs.holder(of: id) } == "Native", "claimed by the native runner")
        #expect(VisorServer.secrets.get(RunnerTokens.key) == nil, "its token held in memory alone")
        // Stopped while it waits for room, before the server stops.
        try await Task.sleep(for: .milliseconds(300))
        running.cancel()
        await running.value
    }
}
}
