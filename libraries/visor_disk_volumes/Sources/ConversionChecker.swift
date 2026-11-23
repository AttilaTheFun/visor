// How the root's check before a swap's or unswap's first rename is run in
// the administrator prompt without running anything the person (or any
// process of theirs, an agent's) could have changed: Visor Disk Utility's
// bundle is copied, as root, into a fresh root-owned folder (mktemp under
// /private/var/tmp, 0700); that copy's signature is verified against a
// requirement built here from constants (Apple's Developer ID anchor, the
// app's identifier, the team the build was made for) and pinned to the
// cdhash of the very process that ran the guard (so the copy must be that
// binary: a bundle replaced after launch, by a build signed by any other
// identity or none, fails); only then is the copy's executable run, and the
// folder is removed as the script ends, whatever happens. Each step stops
// the rest if it fails. Nothing of the requirement is read from the bundle
// on disk.

import Foundation

public struct ConversionChecker: Equatable, Sendable {
    /// The app's bundle, as it runs (`/Applications/Visor Disk Utility.app`).
    public var bundle: String
    /// Its executable's name in `Contents/MacOS` (`Visor Disk Utility`).
    public var executable: String
    /// The code requirement its copy must satisfy (`requirement(team:cdhash:)`).
    public private(set) var requirement: String

    /// The bundle identifier a requirement must name.
    public static let identifier = "com.LoganShire.Visor.DiskUtility"

    /// The certificate extension Apple puts on a Developer ID Application
    /// leaf certificate.
    public static let developerIDLeaf = "1.2.840.113635.100.6.1.13"

    /// The requirement the root's copy must satisfy, built from constants:
    /// with a team, `anchor apple generic and identifier "<id>" and
    /// certificate leaf[field.<Developer ID>] exists and certificate
    /// leaf[subject.OU] = "<team>" and cdhash H"<running cdhash>"`; with
    /// none (a test build's ad hoc signature, allowed only there),
    /// `identifier "<id>" and cdhash H"<running cdhash>"`. Only `and`.
    public static func requirement(team: String?, cdhash: String) -> String {
        let pinned = "identifier \"\(identifier)\" and cdhash H\"\(cdhash)\""
        guard let team else { return pinned }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[field.\(developerIDLeaf)] exists "
            + "and certificate leaf[subject.OU] = \"\(team)\" and cdhash H\"\(cdhash)\""
    }

    /// Whether `team` is a team identifier: ten letters and digits.
    public static func isTeam(_ team: String) -> Bool {
        team.count == 10 && team.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// Whether `cdhash` is a code directory hash: 40 hex digits (SHA-1 or
    /// a SHA-256's first 20 bytes, as codesign prints them).
    public static func isCdhash(_ cdhash: String) -> Bool {
        cdhash.count == 40 && cdhash.allSatisfy(\.isHexDigit)
    }

    /// The script `/bin/sh -c` runs as root: `$1` the bundle, `$2` the
    /// requirement, `$3` the executable's name, then the check's own
    /// arguments.
    public static let script = "set -e; "
        + "d=$(/usr/bin/mktemp -d /private/var/tmp/visor-check.XXXXXXXX); "
        + "trap '/bin/rm -rf \"$d\"' EXIT; "
        + "/usr/sbin/chown root:wheel \"$d\"; /bin/chmod 700 \"$d\"; "
        + "/usr/bin/ditto \"$1\" \"$d/checker.app\"; "
        + "/usr/bin/codesign --verify --strict -R=\"$2\" \"$d/checker.app\" || { echo \"\(refusal)\" >&2; exit 1; }; "
        + "checker=\"$d/checker.app/Contents/MacOS/$3\"; shift 3; "
        + "\"$checker\" \"$@\""

    /// What the script says when the copy fails its verification.
    public static let refusal = "conversion-check refused: the copy of Visor Disk Utility failed its signature check "
        + "(the app was changed since it was looked at, or isn't the one signed). Nothing was changed."

    /// The script's `$0`.
    public static let scriptName = "visor-check"

    /// A checker for the app at `bundle`, its copy pinned to `cdhash`
    /// (the running process's own) and signed by `team` (compiled in, or
    /// the running process's own entitlement's), refused without a team
    /// unless ad hoc signatures are allowed (`adHocAllowed`: a test build's
    /// alone, by its own define).
    public init(bundle: String, executable: String, team: String?, cdhash: String, adHocAllowed: Bool) throws {
        guard bundle.hasPrefix("/"), bundle.hasSuffix(".app"), !bundle.contains("\n") else {
            throw DiskVolumesError.blocked("\(bundle) isn't an app's bundle: the root's check can't be run from it.")
        }
        guard !executable.isEmpty, !executable.contains("/"), executable != "..", !executable.contains("\n") else {
            throw DiskVolumesError.blocked("\(executable) isn't an executable's name.")
        }
        guard Self.isCdhash(cdhash) else {
            throw DiskVolumesError.blocked("Visor Disk Utility's own cdhash couldn't be read (\(cdhash)): the root's check can't be pinned to it.")
        }
        if let team {
            guard Self.isTeam(team) else { throw DiskVolumesError.blocked("\(team) isn't a team identifier.") }
        } else {
            guard adHocAllowed else {
                throw DiskVolumesError.blocked("Visor Disk Utility isn't signed by a team: a build that isn't a test build "
                    + "won't run the root's check by an ad hoc signature.")
            }
        }
        self.bundle = bundle
        self.executable = executable
        self.requirement = Self.requirement(team: team, cdhash: cdhash.lowercased())
    }

    /// The command that runs Visor Disk Utility's `arguments` as root, from
    /// a verified root-owned copy.
    public func command(_ arguments: [String]) -> DiskCommand {
        DiskCommand(program: "/bin/sh", arguments: ["-c", Self.script, Self.scriptName, bundle, requirement, executable] + arguments)
    }
}
