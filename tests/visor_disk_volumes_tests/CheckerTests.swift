// The root's check before a swap's or unswap's first rename runs from a
// copy of Visor Disk Utility made by root in a root-owned folder, verified
// against the running app's designated requirement, never from the bundle
// the person (or an agent of theirs) can write (NCH's review of #506).

import DiskVolumes
import Testing

@Suite struct CheckerTests {
    static let team = "TEAMID0000"
    static let developerID = "identifier \"com.LoganShire.Visor.DiskUtility\" and anchor apple generic and certificate leaf[subject.OU] = TEAMID0000"
    static let adHoc = "cdhash H\"3bc302846ae6cd4e9b5d1c76f7829052ec6ae1d5\""

    @Test func theScriptCopiesVerifiesThenRunsTheCopy() throws {
        let checker = try ConversionChecker(bundle: "/Applications/Visor Disk Utility.app", executable: "Visor Disk Utility",
                                            requirement: Self.developerID, team: Self.team, debugBuild: false)
        let command = checker.command(["conversion-check", "unswap", "sources"])
        #expect(command.argv == ["/bin/sh", "-c", ConversionChecker.script, "visor-check", "/Applications/Visor Disk Utility.app",
                                 Self.developerID, "Visor Disk Utility", "conversion-check", "unswap", "sources"])
        let script = ConversionChecker.script
        // In this order, each stopping the rest (set -e), the folder removed whatever happens.
        let steps = ["set -e;", "/usr/bin/mktemp -d /private/var/tmp/visor-check.XXXXXXXX", "trap '/bin/rm -rf \"$d\"' EXIT",
                     "/usr/sbin/chown root:wheel \"$d\"", "/bin/chmod 700 \"$d\"", "/usr/bin/ditto \"$1\" \"$d/checker.app\"",
                     "/usr/bin/codesign --verify --strict -R=\"$2\" \"$d/checker.app\" || {", "exit 1; }",
                     "checker=\"$d/checker.app/Contents/MacOS/$3\"; shift 3;", "\"$checker\" \"$@\""]
        var from = script.startIndex
        for step in steps {
            let found = try #require(script.range(of: step, range: from..<script.endIndex), "\(step)")
            from = found.upperBound
        }
        #expect(!script.contains("\"$1/Contents"), "the bundle as it is is never run")
        #expect(ConversionChecker.refusal.hasPrefix("conversion-check refused") && ConversionChecker.refusal.hasSuffix("Nothing was changed."))
    }

    @Test func aDeveloperIDBuildsRequirementMustNameTheAnchorIdentifierAndTeam() throws {
        _ = try ConversionChecker(bundle: "/Applications/Visor Disk Utility.app", executable: "Visor Disk Utility",
                                  requirement: Self.developerID.replacingOccurrences(of: "= TEAMID0000", with: "= \"TEAMID0000\""),
                                  team: Self.team, debugBuild: false)
        for weak in ["anchor apple generic", Self.adHoc, "identifier \"com.LoganShire.Visor.DiskUtility\" and anchor apple generic",
                     Self.developerID.replacingOccurrences(of: "anchor apple generic", with: "anchor apple"),
                     Self.developerID.replacingOccurrences(of: "Visor.DiskUtility", with: "Visor"),
                     Self.developerID.replacingOccurrences(of: "TEAMID0000", with: "OTHERTEAM1")] {
            #expect(throws: DiskVolumesError.self, "\(weak)") {
                try ConversionChecker(bundle: "/Applications/Visor Disk Utility.app", executable: "Visor Disk Utility",
                                      requirement: weak, team: Self.team, debugBuild: true)
            }
        }
    }

    @Test func anAdHocBuildIsCheckedByItsCdhashInADebugBuildAlone() throws {
        let checker = try ConversionChecker(bundle: "/tmp/du/Visor Disk Utility.app", executable: "Visor Disk Utility",
                                            requirement: Self.adHoc, team: nil, debugBuild: true)
        #expect(checker.requirement == Self.adHoc)
        let error = #expect(throws: DiskVolumesError.self) {
            try ConversionChecker(bundle: "/tmp/du/Visor Disk Utility.app", executable: "Visor Disk Utility", requirement: Self.adHoc,
                                  team: nil, debugBuild: false)
        }
        #expect(error?.description.contains("isn't signed by a team") == true)
        for unsigned in ["", "anchor apple generic", "identifier \"com.LoganShire.Visor.DiskUtility\""] {
            #expect(throws: DiskVolumesError.self, "\(unsigned)") {
                try ConversionChecker(bundle: "/tmp/du/Visor Disk Utility.app", executable: "Visor Disk Utility", requirement: unsigned,
                                      team: nil, debugBuild: true)
            }
        }
    }

    @Test func onlyAnAppsBundleAndAnExecutablesName() {
        for (bundle, executable) in [("Visor Disk Utility.app", "Visor Disk Utility"), ("/Applications/Visor Disk Utility", "x"),
                                     ("/Applications/Visor Disk Utility.app", "../../bin/sh"), ("/Applications/Visor Disk Utility.app", ""),
                                     ("/Applications/Visor Disk Utility.app", "..")] {
            #expect(throws: DiskVolumesError.self, "\(bundle) \(executable)") {
                try ConversionChecker(bundle: bundle, executable: executable, requirement: Self.adHoc, team: nil, debugBuild: true)
            }
        }
    }
}
