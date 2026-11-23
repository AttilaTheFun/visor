// A build Shireworks hands over is installed only from a checked copy: a
// real folder (a link is refused before anything runs), copied out of the
// app group's container into Visor's own, that copy verified against a
// requirement of Apple's Developer ID, Visor.app's identifier and the team
// the running app is signed for, and assessed by the system (spctl).
// Anything refused leaves the running app as it is (VisorUpdates calls
// installFailed with why).

import Foundation
import Testing
import VisorUpdateInstall

@Suite struct HandedOverBuildTests {
    static let team = "TEAM000001"
    static let requirement = "anchor apple generic and identifier \"com.LoganShire.Visor\" and "
        + "certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
        + "and certificate leaf[subject.OU] = \"TEAM000001\""

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

    func stage(_ runner: FakeRunner, _ place: Place, _ path: String? = nil, team: String? = Self.team) async -> HandedOverBuild.Staged {
        await runner.build.stage(path ?? place.handedOver, in: place.staging, team: team)
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
            [HandedOverBuild.copy, "-R", place.handedOver, copy],
            [HandedOverBuild.codesign, "--verify", "--strict", "--deep", "--test-requirement", "=" + Self.requirement, copy],
            [HandedOverBuild.spctl, "--assess", "--type", "execute", copy],
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

    @Test(arguments: [nil, "", "team000001", "TEAM00001", "TEAM0000011", "TEAM\"0001"])
    func aRunningAppWithNoTeamChecksNothing(team: String?) async throws {
        let place = try Place()
        try place.handOverFolder()
        let runner = FakeRunner()
        guard case .refused = await stage(runner, place, team: team) else {
            Issue.record("a build was taken with no team to check it against")
            return
        }
        #expect(await runner.calls.isEmpty)
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
        #expect(await runner.calls.count == 1)
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
        #expect(!why.contains(Self.team))
        #expect(HandedOverBuild.kind(at: place.staging + "/Visor.app") == .missing)
        #expect(await runner.calls.count == 2)
    }

    @Test func aCopyTheSystemWontRunIsRefusedAndRemoved() async throws {
        let place = try Place()
        try place.handOverFolder()
        let runner = FakeRunner()
        await runner.set(assessOutcome: .init(status: 3, output: "rejected\nsource=Unnotarized Developer ID"))
        guard case .refused(let why) = await stage(runner, place) else {
            Issue.record("a build spctl rejects was taken")
            return
        }
        #expect(why.contains("spctl") && why.contains("Unnotarized"))
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
        #expect(await runner.calls[0] == [HandedOverBuild.copy, "-R", place.handedOver, place.staging + "/Visor.app"])
    }

    @Test func theRequirementNamesDeveloperIDIdentifierAndTeam() {
        #expect(HandedOverBuild.requirement(team: Self.team) == Self.requirement)
    }

    /// Every requirement made carries both Developer ID markers, Apple's
    /// anchor and Visor's identifier, and is joined by `and` alone; one
    /// for a team that isn't one is never made.
    @Test(arguments: ["TEAM000001", "ABCDE12345", "0123456789", "team000001", "", "TEAM00001", "TEAM\" or 1", "TEAM0000011"])
    func noRequirementWithoutItsMarkers(team: String) {
        guard let requirement = HandedOverBuild.requirement(team: team) else {
            #expect(!HandedOverBuild.isTeam(team))
            return
        }
        #expect(HandedOverBuild.isTeam(team))
        #expect(requirement.hasPrefix("anchor apple generic and identifier \"com.LoganShire.Visor\" and "))
        #expect(requirement.contains("certificate 1[field.1.2.840.113635.100.6.2.6] exists"))
        #expect(requirement.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))
        #expect(requirement.hasSuffix("certificate leaf[subject.OU] = \"\(team)\""))
        #expect(!requirement.contains(" or ") && !requirement.contains("!"))
    }
}
