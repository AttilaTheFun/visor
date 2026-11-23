// How the root's check before a swap's or unswap's first rename is run in
// the administrator prompt without running anything the person (or any
// process of theirs, an agent's) could have changed: Visor Disk Utility's
// bundle is copied, as root, into a fresh root-owned folder (mktemp under
// /private/var/tmp, 0700); that copy's signature is verified against the
// running app's own designated requirement (codesign --verify --strict
// -R); only then is the copy's executable run, and the folder is removed
// as the script ends, whatever happens. Each step stops the rest if it
// fails, so a bundle swapped between the guard's look and the prompt is
// refused before it runs as root.

import Foundation

public struct ConversionChecker: Equatable, Sendable {
    /// The app's bundle, as it runs (`/Applications/Visor Disk Utility.app`).
    public var bundle: String
    /// Its executable's name in `Contents/MacOS` (`Visor Disk Utility`).
    public var executable: String
    /// The code requirement its copy must satisfy: the running app's own
    /// designated requirement (`anchor apple generic and identifier
    /// "com.LoganShire.Visor.DiskUtility" and certificate leaf[subject.OU]
    /// = <team>` for a Developer ID build; `cdhash H"…"` for an ad hoc one).
    public var requirement: String

    /// The bundle identifier a requirement must name.
    public static let identifier = "com.LoganShire.Visor.DiskUtility"

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

    /// A checker, refused unless its requirement may be relied on: a build
    /// signed by a team (`teamSigned`) must have the Apple anchor, the
    /// identifier and that team in its requirement; an ad hoc one (its
    /// requirement pins its cdhash) is allowed only in a debug build.
    public init(bundle: String, executable: String, requirement: String, team: String?, debugBuild: Bool) throws {
        guard bundle.hasPrefix("/"), bundle.hasSuffix(".app"), !bundle.contains("\n") else {
            throw DiskVolumesError.blocked("\(bundle) isn't an app's bundle: the root's check can't be run from it.")
        }
        guard !executable.isEmpty, !executable.contains("/"), executable != "..", !executable.contains("\n") else {
            throw DiskVolumesError.blocked("\(executable) isn't an executable's name.")
        }
        let text = requirement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DiskVolumesError.blocked("Visor Disk Utility isn't signed: the root's check can't be verified.") }
        if let team, !team.isEmpty {
            guard text.contains("anchor apple generic"), text.contains("identifier \"\(Self.identifier)\""),
                  text.contains("certificate leaf[subject.OU] = \"\(team)\"") || text.contains("certificate leaf[subject.OU] = \(team)") else {
                throw DiskVolumesError.blocked("Visor Disk Utility's designated requirement (\(text)) doesn't name Apple's anchor, its identifier "
                    + "and its team: the root's check can't be verified by it.")
            }
        } else {
            guard debugBuild, text.hasPrefix("cdhash H\"") || text.hasPrefix("cdhash H'") else {
                throw DiskVolumesError.blocked("Visor Disk Utility isn't signed by a team (\(text)): a build of it that isn't a debug one "
                    + "won't run the root's check by an ad hoc signature.")
            }
        }
        self.bundle = bundle
        self.executable = executable
        self.requirement = text
    }

    /// The command that runs Visor Disk Utility's `arguments` as root, from
    /// a verified root-owned copy.
    public func command(_ arguments: [String]) -> DiskCommand {
        DiskCommand(program: "/bin/sh", arguments: ["-c", Self.script, Self.scriptName, bundle, requirement, executable] + arguments)
    }
}
