// The root's check before a swap's or unswap's first rename runs from a
// copy of Visor Disk Utility made by root in a root-owned folder, verified
// against a requirement built from constants (Apple's Developer ID anchor,
// the identifier, the team) and pinned to the running process's own
// cdhash, never one read from the bundle the person (or an agent of
// theirs) can write (NCH's reviews of #508).

import DiskVolumes
import Testing

@Suite struct CheckerTests {
    static let team = "TEAMID0000"
    static let cdhash = "3bc302846ae6cd4e9b5d1c76f7829052ec6ae1d5"

    private func checker(team: String? = CheckerTests.team, cdhash: String = CheckerTests.cdhash, adHocAllowed: Bool = false,
                         bundle: String = "/Applications/Visor Disk Utility.app",
                         executable: String = "Visor Disk Utility") throws -> ConversionChecker {
        try ConversionChecker(bundle: bundle, executable: executable, team: team, cdhash: cdhash, adHocAllowed: adHocAllowed)
    }

    @Test func theRequirementIsBuiltFromConstantsAndPinnedToTheRunningCdhash() throws {
        let signed = try checker()
        #expect(signed.requirement == "anchor apple generic and identifier \"com.LoganShire.Visor.DiskUtility\" and certificate "
            + "leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"TEAMID0000\" "
            + "and cdhash H\"3bc302846ae6cd4e9b5d1c76f7829052ec6ae1d5\"")
        // Only `and`: nothing in it can be satisfied another way.
        #expect(!signed.requirement.contains(" or "))
        #expect(!signed.requirement.contains("!"))
        #expect(signed.requirement.hasSuffix("and cdhash H\"\(Self.cdhash)\""))
        // An uppercase cdhash is pinned as codesign prints it.
        #expect(try checker(cdhash: Self.cdhash.uppercased()).requirement == signed.requirement)
        // A test build's ad hoc signature: the identifier and the cdhash alone.
        #expect(try checker(team: nil, adHocAllowed: true).requirement
                == "identifier \"com.LoganShire.Visor.DiskUtility\" and cdhash H\"3bc302846ae6cd4e9b5d1c76f7829052ec6ae1d5\"")
    }

    @Test func theScriptCopiesVerifiesThenRunsTheCopy() throws {
        let checker = try checker()
        let command = checker.command(["conversion-check", "unswap", "sources"])
        #expect(command.argv == ["/bin/sh", "-c", ConversionChecker.script, "visor-check", "/Applications/Visor Disk Utility.app",
                                 checker.requirement, "Visor Disk Utility", "conversion-check", "unswap", "sources"])
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

    @Test func withoutATeamOnlyATestBuildIsChecked() throws {
        // A build that isn't a test build (whatever its optimisation: DEBUG
        // is no gate, as fastbuild defines it too) refuses an ad hoc signature.
        let error = #expect(throws: DiskVolumesError.self) { try checker(team: nil, adHocAllowed: false) }
        #expect(error?.description.contains("isn't signed by a team") == true)
        _ = try checker(team: nil, adHocAllowed: true)
    }

    @Test func onlyATeamACdhashAnAppsBundleAndAnExecutablesName() {
        for team in ["", "TEAM", "teamid0000", "TEAMID0000\" or anchor apple", "TEAMID00000"] {
            #expect(throws: DiskVolumesError.self, "\(team)") { try checker(team: team) }
        }
        for cdhash in ["", "3bc3", String(repeating: "g", count: 40), Self.cdhash + "\" or anchor apple generic and cdhash H\"" + Self.cdhash] {
            #expect(throws: DiskVolumesError.self, "\(cdhash)") { try checker(cdhash: cdhash) }
        }
        for (bundle, executable) in [("Visor Disk Utility.app", "Visor Disk Utility"), ("/Applications/Visor Disk Utility", "x"),
                                     ("/Applications/Visor Disk Utility.app", "../../bin/sh"), ("/Applications/Visor Disk Utility.app", ""),
                                     ("/Applications/Visor Disk Utility.app", "..")] {
            #expect(throws: DiskVolumesError.self, "\(bundle) \(executable)") { try checker(bundle: bundle, executable: executable) }
        }
    }
}
