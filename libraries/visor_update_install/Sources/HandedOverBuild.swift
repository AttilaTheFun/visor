import Foundation

/// A build Shireworks handed over for Visor.app to install itself
/// (Shireworks Kit's `UpdateOffer.bundle`), made safe to install. It lies in the
/// app group's container, which every member of the group may write, so it
/// is taken only when it is a real folder, not a symbolic link (lstat);
/// then copied into a folder of Visor's own, and that copy, the one that is
/// installed, checked: `codesign --verify --strict --deep` against a
/// requirement built here from constants (Apple's anchor, the Developer ID
/// intermediate and leaf markers, this app's identifier) and the team the
/// running app is signed for, as the kernel holds it (the caller's, never
/// read from a bundle on disk); and `spctl --assess --type execute`, the
/// system's own verdict (notarized). A build of another identifier or
/// team, one signed for development or distribution rather than Developer
/// ID, one changed since it was signed, or one the system won't run, is
/// refused. What it can't take, it says why, for Shireworks Kit's
/// `installFailed`; the running app stays.
public struct HandedOverBuild: Sendable {
    /// A command's end: its exit status and what it wrote (its output and
    /// its errors together).
    public struct Outcome: Sendable, Equatable {
        public var status: Int32
        public var output: String

        public init(status: Int32, output: String = "") {
            self.status = status
            self.output = output
        }
    }

    /// A command run to its end: the program by its full path, and its
    /// arguments.
    public typealias Run = @Sendable (_ program: String, _ arguments: [String]) async -> Outcome

    /// What a file is, its link not followed (lstat).
    public enum Kind: Sendable, Equatable {
        case folder, link, other, missing
    }

    /// The handed-over build: its copy, checked, ready to install; or why
    /// it isn't installed.
    public enum Staged: Sendable, Equatable {
        case ready(String)
        case refused(String)
    }

    /// The bundle identifier a build to install must have: Visor.app's.
    public static let identifier = "com.LoganShire.Visor"

    public static let codesign = "/usr/bin/codesign"
    public static let copy = "/bin/cp"
    public static let spctl = "/usr/sbin/spctl"

    /// The extension Apple puts on the Developer ID Certification
    /// Authority, the leaf's issuer (certificate 1).
    public static let developerIDIntermediate = "1.2.840.113635.100.6.2.6"
    /// The extension Apple puts on a Developer ID Application leaf
    /// certificate.
    public static let developerIDLeaf = "1.2.840.113635.100.6.1.13"

    let run: Run
    let kind: @Sendable (String) -> Kind

    /// `run` runs the commands (`processes`, or a fake); `kind` says what a
    /// file is (`kind(at:)`, or a fake).
    public init(run: @escaping Run, kind: @escaping @Sendable (String) -> Kind = { HandedOverBuild.kind(at: $0) }) {
        self.run = run
        self.kind = kind
    }

    /// The handed-over build at `handedOver` copied into `folder` (a folder
    /// of this app's own, made if it isn't there; a copy left there before
    /// is replaced) and checked against Visor.app's identifier and `team`,
    /// the team the running app is signed for as the kernel holds it (nil:
    /// none, an ad hoc build, which installs nothing). A copy that fails is
    /// removed.
    public func stage(_ handedOver: String, in folder: String, team: String?) async -> Staged {
        let source = Self.trimmed(handedOver)
        switch kind(source) {
        case .folder: break
        case .link: return .refused("The build Shireworks handed over (\(source)) is a symbolic link, not a folder: it isn't installed")
        case .missing: return .refused("The build Shireworks handed over isn't at \(source)")
        case .other: return .refused("The build Shireworks handed over (\(source)) isn't a folder: it isn't installed")
        }
        guard let team else {
            return .refused("This build of Visor is signed for no team, so no build can be checked against it: the update isn't installed")
        }
        guard let requirement = Self.requirement(team: team) else {
            return .refused("This build's team can't be checked against: the update isn't installed")
        }
        let files = FileManager.default
        do {
            try files.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .refused("No folder for the update at \(folder): \(error.localizedDescription)")
        }
        let staged = (folder as NSString).appendingPathComponent((source as NSString).lastPathComponent)
        if kind(staged) != .missing { try? files.removeItem(atPath: staged) }
        let copied = await run(Self.copy, ["-R", source, staged])
        guard copied.status == 0, kind(staged) == .folder else {
            try? files.removeItem(atPath: staged)
            return .refused("The build Shireworks handed over couldn't be copied out of the app group's container: "
                            + Self.said(copied))
        }
        let verified = await run(Self.codesign, ["--verify", "--strict", "--deep", "--test-requirement", "=" + requirement, staged])
        guard verified.status == 0 else {
            try? files.removeItem(atPath: staged)
            return .refused("The build Shireworks handed over failed its signature check (Apple's Developer ID, \(Self.identifier), this "
                            + "build's team): " + Self.said(verified))
        }
        let assessed = await run(Self.spctl, ["--assess", "--type", "execute", staged])
        guard assessed.status == 0 else {
            try? files.removeItem(atPath: staged)
            return .refused("The system won't run the build Shireworks handed over (spctl): " + Self.said(assessed))
        }
        return .ready(staged)
    }

    /// The requirement a build to install must meet, built from constants
    /// and `team`, or nil when that isn't a team (no requirement without
    /// its markers is ever made): Apple's anchor, Visor.app's identifier,
    /// the Developer ID intermediate's and leaf's markers, and the team's
    /// leaf certificate. Only `and`.
    public static func requirement(team: String) -> String? {
        guard isTeam(team) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate 1[field.\(developerIDIntermediate)] exists "
            + "and certificate leaf[field.\(developerIDLeaf)] exists and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Whether `team` is a team identifier: ten capital letters and digits.
    public static func isTeam(_ team: String) -> Bool {
        team.count == 10 && team.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// What a file at `path` is, a link not followed.
    public static func kind(at path: String) -> Kind {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else {
            return .missing
        }
        switch type {
        case .typeDirectory: return .folder
        case .typeSymbolicLink: return .link
        default: return .other
        }
    }

    /// A path without the slash a folder's may end with.
    static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// What a command said, or its status.
    static func said(_ outcome: Outcome) -> String {
        let output = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "it ended with \(outcome.status)" : output
    }
}
