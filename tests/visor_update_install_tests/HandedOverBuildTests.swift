// A build Shireworks hands over is installed only from a checked copy:
// a real folder (a link is refused before anything runs), copied out of the
// app group's container into Visor's own, and that copy verified against
// the running app's identifier and team. Anything refused leaves the
// running app as it is (VisorUpdates calls installFailed with why).

import Foundation
import Testing
import VisorUpdateInstall

@Suite struct HandedOverBuildTests {
    static let bundleID = "com.LoganShire.Visor"
    static let requirement = "anchor apple generic and identifier \"com.LoganShire.Visor\" and certificate leaf[subject.OU] = \"TEAM000001\""

    /// A folder of the test's own: the group's container's stand-in, and
    /// Visor's staging folder in it.
    final class Place {
        let root: String
        var container: String { root + "/container" }
        var staging: String { root + "/staging" }
        var handedOver: String { container + "/Visor.app" }

        init() throws {
            root = NSTemporaryDirectory() + "handed-over-" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: root + "/container", withIntermediateDirectories: true)
        }

        func handOverFolder() throws {
            try FileManager.default.createDirectory(atPath: handedOver + "/Contents/MacOS", withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(atPath: root) }
    }

    func stage(_ runner: FakeRunner, _ place: Place, _ path: String? = nil) async -> HandedOverBuild.Staged {
        await runner.build.stage(path ?? place.handedOver, in: place.staging, bundleID: Self.bundleID,
                                 ownBundle: "/Applications/Visor.app")
    }

    @Test func aCheckedCopyIsReady() async throws {
        let place = try Place()
        try place.handOverFolder()
        let runner = FakeRunner()
        let staged = await stage(runner, place)
        let copy = place.staging + "/Visor.app"
        #expect(staged == .ready(copy))
        #expect(HandedOverBuild.kind(at: copy) == .folder)
        let calls = await runner.calls
        #expect(calls == [
            [HandedOverBuild.codesign, "-d", "-r-", "/Applications/Visor.app"],
            [HandedOverBuild.copy, "-R", place.handedOver, copy],
            [HandedOverBuild.codesign, "--verify", "--strict", "--deep", "--test-requirement", "=" + Self.requirement, copy],
        ])
    }

    @Test func aLinkIsRefusedBeforeAnythingRuns() async throws {
        let place = try Place()
        try FileManager.default.createDirectory(atPath: place.root + "/elsewhere.app/Contents/MacOS", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: place.handedOver, withDestinationPath: place.root + "/elsewhere.app")
        let runner = FakeRunner()
        guard case .refused(let why) = await stage(runner, place) else {
            Issue.record("a link was taken")
            return
        }
        #expect(why.contains("symbolic link"))
        #expect(await runner.calls.isEmpty)
        #expect(HandedOverBuild.kind(at: place.staging + "/Visor.app") == .missing)
    }

    @Test func aFileOrNothingIsRefused() async throws {
        let place = try Place()
        let runner = FakeRunner()
        guard case .refused(let missing) = await stage(runner, place) else {
            Issue.record("nothing was taken")
            return
        }
        #expect(missing.contains("isn't at"))
        try Data("not an app".utf8).write(to: URL(fileURLWithPath: place.handedOver))
        guard case .refused(let file) = await stage(runner, place) else {
            Issue.record("a file was taken")
            return
        }
        #expect(file.contains("isn't a folder"))
        #expect(await runner.calls.isEmpty)
    }

    @Test func aRunningAppWithNoTeamChecksNothing() async throws {
        let place = try Place()
        try place.handOverFolder()
        let runner = FakeRunner()
        // An ad hoc build's requirement: its code hash alone.
        await runner.set(ownRequirement: "designated => cdhash H\"0123456789abcdef0123456789abcdef01234567\"")
        guard case .refused(let why) = await stage(runner, place) else {
            Issue.record("a build was taken with no team to check it against")
            return
        }
        #expect(why.contains("names no team"))
        #expect(await runner.calls.count == 1)
    }

    @Test func aCopyThatFailsIsRefused() async throws {
        let place = try Place()
        try place.handOverFolder()
        let runner = FakeRunner()
        await runner.set(copyStatus: 1)
        guard case .refused(let why) = await stage(runner, place) else {
            Issue.record("a failed copy was taken")
            return
        }
        #expect(why.contains("Permission denied"))
        #expect(await runner.calls.count == 2)
    }

    @Test func aCopyThatFailsItsCheckIsRefusedAndRemoved() async throws {
        let place = try Place()
        try place.handOverFolder()
        let runner = FakeRunner()
        await runner.set(verifyOutcome: .init(status: 3, output: "test-requirement: code failed to satisfy specified code requirement(s)"))
        guard case .refused(let why) = await stage(runner, place) else {
            Issue.record("a build that failed its check was taken")
            return
        }
        #expect(why.contains("failed its signature check"))
        #expect(why.contains("failed to satisfy"))
        #expect(HandedOverBuild.kind(at: place.staging + "/Visor.app") == .missing)
    }

    @Test func aCopyLeftBeforeIsReplaced() async throws {
        let place = try Place()
        try place.handOverFolder()
        let stale = place.staging + "/Visor.app/stale"
        try FileManager.default.createDirectory(atPath: stale, withIntermediateDirectories: true)
        let runner = FakeRunner()
        #expect(await stage(runner, place) == .ready(place.staging + "/Visor.app"))
        #expect(HandedOverBuild.kind(at: stale) == .missing)
    }

    @Test func aTrailingSlashIsTheSameFolder() async throws {
        let place = try Place()
        try place.handOverFolder()
        let runner = FakeRunner()
        #expect(await stage(runner, place, place.handedOver + "/") == .ready(place.staging + "/Visor.app"))
        #expect(await runner.calls[1] == [HandedOverBuild.copy, "-R", place.handedOver, place.staging + "/Visor.app"])
    }

    @Test(arguments: [
        ("designated => anchor apple generic and certificate leaf[subject.OU] = TEAM000001)", "TEAM000001"),
        ("designated => anchor apple generic and certificate leaf[subject.OU] = \"TEAM000001\"", "TEAM000001"),
        ("certificate leaf[subject.OU]=TEAM000001", "TEAM000001"),
    ])
    func theTeamIsReadFromTheRequirement(text: String, team: String) {
        #expect(HandedOverBuild.team(inRequirement: text) == team)
    }

    @Test(arguments: ["designated => cdhash H\"0123\"", "designated => identifier \"x\"", "leaf[subject.OU] = \"\""])
    func noTeamIsNone(text: String) {
        #expect(HandedOverBuild.team(inRequirement: text) == nil)
    }

    @Test func theRequirementNamesIdentifierAndTeam() {
        #expect(HandedOverBuild.requirement(bundleID: Self.bundleID, team: "TEAM000001") == Self.requirement)
    }

    @Test func aBundleIDThatIsntOneChecksNothing() async throws {
        let place = try Place()
        try place.handOverFolder()
        let runner = FakeRunner()
        let staged = await runner.build.stage(place.handedOver, in: place.staging, bundleID: "com.x\" or true",
                                              ownBundle: "/Applications/Visor.app")
        guard case .refused = staged else {
            Issue.record("a bundle id with a quote went into the requirement")
            return
        }
        #expect(await runner.calls.isEmpty)
    }
}
