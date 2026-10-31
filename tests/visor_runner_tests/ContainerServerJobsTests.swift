// The Runner's container servers (docs/co-tenancy.md) over scripts that play
// launchctl, which keeps what is loaded in files, and a container host,
// which writes down what it was asked.
import Foundation
import VisorContainerHost
import VisorRunner
import XCTest

final class ContainerServerJobsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("loaded"), withIntermediateDirectories: true)
        try script("launchctl", """
            #!/bin/bash
            dir="\(root.path)"
            echo "launchctl $*" >> "$dir/calls"
            case "$1" in
              print) [ -e "$dir/loaded/${2#*/*/}" ] ;;
              bootstrap) label=$(sed -n '/<key>Label<\\/key>/{n;s/.*<string>\\(.*\\)<\\/string>.*/\\1/p;}' "$3")
                         [ -e "$dir/loaded/$label" ] && { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
                         touch "$dir/loaded/$label" ;;
              bootout) rm -f "$dir/loaded/${2#*/*/}" ;;
            esac
            """)
        try writeHost()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func script(_ name: String, _ text: String) throws {
        let file = root.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    /// The host: each command written down with its input; `credentials`
    /// answers what it kept, a folder named "fails" fails.
    private func writeHost(_ extra: String = "") throws {
        try script("host", """
            #!/bin/bash
            dir="\(root.path)"
            input=""; [ "$1" = credentials ] && input=$(cat)
            echo "host $* $input" >> "$dir/calls"
            case "$2" in *fails*) echo '{"error": "it failed"}'; exit 1 ;; esac
            case "$1" in
              credentials) echo '{"kept": ["claudeToken"]}' ;;
              *) echo '{}' ;;
            esac
            # \(extra)
            """)
    }

    private var host: String { root.appendingPathComponent("host").path }

    private var jobs: ContainerServerJobs {
        ContainerServerJobs(bundledHost: host, folders: root.appendingPathComponent("container-servers"), labelPrefix: "test.runner",
                            agents: root.appendingPathComponent("LaunchAgents"),
                            launchctl: Launchctl(program: root.appendingPathComponent("launchctl").path, domain: "gui/501"),
                            path: [root.path])
    }

    private var calls: [String] {
        ((try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func clearCalls() { try? FileManager.default.removeItem(at: root.appendingPathComponent("calls")) }

    private func loaded(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("loaded/test.runner.container-server.\(id)").path)
    }

    private func plist(_ id: String) -> URL {
        root.appendingPathComponent("LaunchAgents/test.runner.container-server.\(id).plist")
    }

    func testAServerMadeIsAFolderAndAJobThatServesIt() throws {
        var spec = ServerSpec(id: "s1", name: "Builds", image: "visor-agent:0.45.0")
        spec.listen.port = 7440
        XCTAssertNil(try jobs.make(spec))
        let folder = jobs.folder("s1")
        XCTAssertEqual(try ServerSpec.read(folder), spec)
        let job = try XCTUnwrap(LaunchJob.read(plist("s1")))
        XCTAssertEqual(job.label, "test.runner.container-server.s1")
        XCTAssertEqual(job.programArguments, [host, "serve", folder.path])
        XCTAssertTrue(job.keepAlive && job.runAtLoad)
        XCTAssertEqual(job.standardErrorPath, folder.appendingPathComponent("host.log").path)
        XCTAssertTrue(loaded("s1"))
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700, "the folder is this user's alone")
        XCTAssertEqual(jobs.servers().map(\.name), ["Builds"])
    }

    func testRefreshLeavesAJobAsItIsUntilItsHostChanges() throws {
        XCTAssertNil(try jobs.make(ServerSpec(id: "s1", name: "Builds", image: "i")))
        clearCalls()
        XCTAssertEqual(jobs.refresh(), [:])
        XCTAssertFalse(calls.contains { $0.contains("bootstrap") || $0.contains("bootout") }, "a job as it should be is left running")

        // A new build of the host (another size): its job is loaded again.
        try writeHost("a new build")
        XCTAssertEqual(jobs.refresh(), [:])
        let order = calls.filter { $0.contains("bootout") || $0.contains("bootstrap") }
        XCTAssertEqual(order.count, 2)
        XCTAssertTrue(order[0].contains("bootout gui/501/test.runner.container-server.s1"))
        XCTAssertTrue(order[1].contains("bootstrap gui/501"))
        XCTAssertTrue(loaded("s1"))
        XCTAssertFalse(calls.contains { $0.hasPrefix("host stop") || $0.hasPrefix("host remove") }, "its container left running")
    }

    func testAJobUnloadedFromOutsideIsLoadedAgain() throws {
        XCTAssertNil(try jobs.make(ServerSpec(id: "s1", name: "Builds", image: "i")))
        try FileManager.default.removeItem(at: root.appendingPathComponent("loaded/test.runner.container-server.s1"))
        XCTAssertEqual(jobs.refresh(), [:])
        XCTAssertTrue(loaded("s1"))
    }

    func testAStoppedServerStaysStoppedUntilStarted() throws {
        XCTAssertNil(try jobs.make(ServerSpec(id: "s1", name: "Builds", image: "i")))
        XCTAssertNil(jobs.stop("s1"))
        XCTAssertFalse(loaded("s1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist("s1").path))
        XCTAssertTrue(calls.contains("host stop \(jobs.folder("s1").path) "))
        XCTAssertEqual(jobs.refresh(), [:])
        XCTAssertFalse(loaded("s1"), "a refresh doesn't start a stopped server")
        XCTAssertNil(jobs.start("s1"))
        XCTAssertTrue(loaded("s1"))
        XCTAssertFalse(jobs.record("s1").stopped)
    }

    func testAJobWhoseServerIsGoneIsUnloaded() throws {
        XCTAssertNil(try jobs.make(ServerSpec(id: "s1", name: "Builds", image: "i")))
        try FileManager.default.removeItem(at: jobs.folder("s1"))
        XCTAssertEqual(jobs.refresh(), [:])
        XCTAssertFalse(loaded("s1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist("s1").path))
    }

    func testRemovingAServerTakesItsDisksAndFolder() throws {
        XCTAssertNil(try jobs.make(ServerSpec(id: "s1", name: "Builds", image: "i")))
        let folder = jobs.folder("s1").path
        XCTAssertNil(jobs.remove("s1"))
        XCTAssertFalse(loaded("s1"))
        XCTAssertTrue(calls.contains("host remove \(folder) --data "))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
    }

    func testAHostThatFailsSaysSoAndKeepsTheFolder() throws {
        XCTAssertNil(try jobs.make(ServerSpec(id: "fails", name: "Broken", image: "i")))
        XCTAssertEqual(jobs.remove("fails"), "it failed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobs.folder("fails").path), "kept, to try again")
    }

    func testCredentialsGoToTheHostOnItsInput() throws {
        XCTAssertNil(try jobs.make(ServerSpec(id: "s1", name: "Builds", image: "i")))
        let given = Data(#"{"claudeToken": "t"}"#.utf8)
        XCTAssertEqual(try jobs.credentials("s1", given).get(), ["claudeToken"])
        XCTAssertTrue(calls.contains("host credentials \(jobs.folder("s1").path) {\"claudeToken\": \"t\"}"))
    }

    func testAServerMadeWithCredentialsHasThemBeforeItsJobStarts() throws {
        XCTAssertNil(try jobs.make(ServerSpec(id: "s1", name: "Builds", image: "i"), credentials: Data(#"{"openrouterKey": "k"}"#.utf8)))
        let order = calls.filter { $0.hasPrefix("host credentials") || $0.contains("bootstrap") }
        XCTAssertEqual(order.count, 2)
        XCTAssertTrue(order[0].hasPrefix("host credentials"), "given first: \(order)")
    }

    func testAHostNamedWithoutAPathIsFoundOnThePath() throws {
        XCTAssertNil(try jobs.make(ServerSpec(id: "s1", name: "Builds", image: "i"), host: ["host", "container-host"]))
        let job = try XCTUnwrap(LaunchJob.read(plist("s1")))
        XCTAssertEqual(job.programArguments, [host, "container-host", "serve", jobs.folder("s1").path])
        XCTAssertNotNil(try jobs.make(ServerSpec(id: "s2", name: "Lost", image: "i"), host: ["no-such-host"]), "an error, not a job")
        XCTAssertFalse(loaded("s2"))
    }
}
