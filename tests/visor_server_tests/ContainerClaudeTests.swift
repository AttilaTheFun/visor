// Containers only means no Claude Code of this Mac's own
// (VisorServer+ContainerClaude): while the Sessions container is on, the
// server's own `claude -p` runs there (a fake container here), with the
// container's Claude folder on Sessions; with it off, here as before.

import Foundation
import Synchronization
import VisorProtocol
@testable import VisorServer
import VisorSystem
import Testing

extension ServerTests {
@Suite @MainActor final class ContainerClaudeTests {
    final class CommandContainer: SessionsContainer {
        let ran = Mutex<[ContainerCommand]>([])
        let state: ContainerState
        let answer: String

        init(state: ContainerState, answer: String) {
            self.state = state
            self.answer = answer
        }

        func status() async -> ContainerStatus { ContainerStatus(state: state, enabled: true, canRun: true) }
        func start() async -> ContainerStatus { await status() }
        func stop() async -> ContainerStatus { await status() }
        func restart() async -> ContainerStatus { await status() }
        var sharedFolders: [String] { ["/Volumes/Sessions"] }
        func startAgent(_ agent: ContainerAgent) async throws -> any ContainerAgentRun { throw CancellationError() }
        func settingsChanged(_ settings: ServerSettings) {}
        func loopbackPortIsFree(_ port: Int) -> Bool { true }

        func run(_ command: ContainerCommand) async throws -> ContainerCommandOutput {
            ran.withLock { $0.append(command) }
            return ContainerCommandOutput(status: 0, text: answer, stopped: false)
        }
    }

    private var server: VisorServer!
    private var root: URL!

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-container-claude-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: ServerTestCase.freePort())
    }

    isolated deinit {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func turnOn(_ on: Bool) {
        var container = server.settings.container ?? ContainerSettings()
        container.enabled = on
        server.settings.container = container
    }

    static let models = #"{"type":"control_response","response":{"subtype":"success","request_id":"visor-models","response":{"models":[]}}}"#

    @Test func theModelsAreAskedOfTheContainerWhileItsOnAndRunning() async {
        let container = CommandContainer(state: .running, answer: "noise\n" + Self.models + "\n")
        server.sessionsContainer = container
        turnOn(true)
        #expect(server.claudeRunsInContainer)
        _ = await server.refreshClaudeModels()
        let ran = container.ran.withLock { $0 }
        #expect(ran.count == 1)
        #expect(ran.first?.arguments == ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"])
        #expect(ran.first?.environment == ["CLAUDE_CONFIG_DIR": "/Volumes/Sessions/.claude"])
        #expect(ran.first.map { String(decoding: $0.input ?? Data(), as: UTF8.self) }?.contains(#""subtype":"initialize""#) == true)
        #expect(ran.first?.answered(Self.models) == true, "it's ended once it has answered")
        #expect(ran.first?.answered("noise") == false)
    }

    @Test func aStoppedContainerIsntStartedForTheModels() async {
        let container = CommandContainer(state: .stopped, answer: "")
        server.sessionsContainer = container
        turnOn(true)
        #expect(await server.refreshClaudeModels() == .unchanged)
        #expect(container.ran.withLock { $0 }.isEmpty)
    }

    @Test func superCompactCallsGoToTheContainerWhileItsOn() async throws {
        let answer = #"{"type":"result","subtype":"success","is_error":false,"result":"the handoff"}"#
        let container = CommandContainer(state: .stopped, answer: answer)
        server.sessionsContainer = container
        turnOn(false)
        #expect(server.superCompactCaller() == nil, "off: claude runs here, as before")
        turnOn(true)
        #expect(server.superCompactProgram() == "claude")
        let caller = try #require(server.superCompactCaller())
        let outcome = await SuperCompaction.call(tool: "claude", model: "haiku", prompt: "the chunk", in: root, limit: .seconds(30),
                                                 stop: SuperCompaction.Stop(), caller: caller)
        #expect(try outcome.get() == "the handoff")
        let ran = try #require(container.ran.withLock { $0 }.first)
        #expect(ran.arguments.first == "claude")
        #expect(Array(ran.arguments.dropFirst()) == SuperCompaction.arguments(model: "haiku"))
        #expect(ran.input == Data("the chunk".utf8))
        #expect(ran.environment["CLAUDE_CONFIG_DIR"] == "/Volumes/Sessions/.claude")
    }
}
}
