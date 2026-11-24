// Whether the menu bar app relaunches into the bundle on disk
// (AppRelaunchCheck): only into a whole bundle of another version or build,
// from /Applications, with no update's watch holding its lock. The bundles
// are real folders, read as the app reads its own.

import Foundation
import Testing
import VisorServer
@testable import VisorLaunchAgent

@Suite struct AppRelaunchCheckTests {
    let running = AppRelaunchCheck.Build(identifier: "com.LoganShire.Visor", version: "0.69.1", build: "1")

    /// A bundle in a folder of its own: its Info.plist (none when `info` is
    /// nil) and, unless `executable` is false, the executable it names.
    func bundle(_ info: [String: String]?, executable: Bool = true) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("app-relaunch-\(UUID().uuidString)", isDirectory: true)
        let app = folder.appendingPathComponent("Visor.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        if let info {
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        }
        if executable {
            let path = macOS.appendingPathComponent(info?["CFBundleExecutable"] ?? "Visor").path
            #expect(FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8)))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        return app.path
    }

    func info(version: String, build: String = "1", identifier: String = "com.LoganShire.Visor") -> [String: String] {
        ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleVersion": build,
         "CFBundleExecutable": "Visor"]
    }

    func decide(_ bundle: String, inApplications: Bool = true, watchLeft: Int? = nil) -> AppRelaunchCheck.Decision {
        AppRelaunchCheck.decide(running: running, inApplications: inApplications, onDisk: AppRelaunchCheck.onDisk(bundle),
                                watchLeft: watchLeft)
    }

    @Test func theSameBuildOnDiskStays() throws {
        let decision = decide(try bundle(info(version: "0.69.1")))
        #expect(decision == .stay("the bundle on disk is the build running (0.69.1)"))
        #expect(!decision.relaunches)
    }

    @Test func anotherVersionOnDiskRelaunches() throws {
        let decision = decide(try bundle(info(version: "0.70.0")))
        #expect(decision == .relaunch("the bundle on disk is 0.70.0, this process runs 0.69.1"))
        #expect(decision.relaunches)
        // Older too: a rollback put the previous build back.
        #expect(decide(try bundle(info(version: "0.68.1"))).relaunches)
    }

    @Test func anotherBuildOfTheSameVersionRelaunches() throws {
        #expect(decide(try bundle(info(version: "0.69.1", build: "2"))).relaunches)
        let old = AppRelaunchCheck.Build(identifier: "com.LoganShire.Visor", version: "0.35", build: "21")
        let disk = AppRelaunchCheck.onDisk(try bundle(info(version: "0.35", build: "22")))
        #expect(AppRelaunchCheck.decide(running: old, inApplications: true, onDisk: disk, watchLeft: nil)
            == .relaunch("the bundle on disk is 0.35 (22), this process runs 0.35 (21)"))
    }

    @Test func anIncompleteBundleStays() throws {
        // No executable (yet): an install still copying.
        let noExecutable = try bundle(info(version: "0.70.0"), executable: false)
        #expect(AppRelaunchCheck.onDisk(noExecutable) == .incomplete("\(noExecutable)/Contents/MacOS/Visor isn't there (yet)"))
        #expect(!decide(noExecutable).relaunches)
        // No Info.plist.
        let noInfo = try bundle(nil)
        #expect(AppRelaunchCheck.onDisk(noInfo) == .incomplete("\(noInfo) has no readable Info.plist"))
        #expect(!decide(noInfo).relaunches)
        // An Info.plist that isn't one.
        let unreadable = try bundle(nil)
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: unreadable + "/Contents/Info.plist"))
        #expect(!decide(unreadable).relaunches)
        // Nothing there at all: the bundle moved aside mid-install.
        #expect(!decide("/nonexistent/Visor.app").relaunches)
        // An Info.plist with no version.
        #expect(!decide(try bundle(["CFBundleIdentifier": "com.LoganShire.Visor", "CFBundleExecutable": "Visor"])).relaunches)
    }

    @Test func anUpdatesWatchHoldingTheLockWaits() throws {
        let newer = try bundle(info(version: "0.70.0"))
        let left = AppRelaunchCheck.watchLeft(lock: "4242 1000\n", now: 1100, isRunning: { $0 == 4242 })
        #expect(left == RelaunchWatchLock.longest - 100)
        let decision = decide(newer, watchLeft: left)
        #expect(!decision.relaunches)
        guard case .later(_, let seconds) = decision else {
            Issue.record("expected to look again later, got \(decision)")
            return
        }
        #expect(seconds == RelaunchWatchLock.longest - 100)
        // A lock whose watcher has gone, or none: relaunched.
        #expect(AppRelaunchCheck.watchLeft(lock: "4242 1000\n", now: 1100, isRunning: { _ in false }) == nil)
        #expect(AppRelaunchCheck.watchLeft(lock: nil, now: 1100, isRunning: { _ in true }) == nil)
        #expect(decide(newer, watchLeft: nil).relaunches)
    }

    @Test func aCopyOutsideApplicationsStays() throws {
        let newer = try bundle(info(version: "0.70.0"))
        #expect(!decide(newer, inApplications: false).relaunches)
        #expect(AppRelaunchCheck.inApplications("/Applications/Visor.app"))
        #expect(!AppRelaunchCheck.inApplications("/Applications/Tools/Visor.app"))
        #expect(!AppRelaunchCheck.inApplications("/Users/me/bazel-bin/applications/visor_mac/Visor.app"))
        #expect(!AppRelaunchCheck.inApplications("/Applications"))
    }

    @Test func anotherAppInItsPlaceStays() throws {
        let other = try bundle(info(version: "0.70.0", identifier: "com.example.Other"))
        #expect(decide(other) == .stay("the bundle on disk is com.example.Other, not com.LoganShire.Visor"))
    }
}
