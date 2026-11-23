import Foundation

/// A build Shireworks handed over for Visor.app to install itself
/// (UpdateKit's `UpdateOffer.bundle`), made safe to install. It lies in the
/// app group's container, which every member of the group may write, so it
/// is taken only when it is a real folder, not a symbolic link (lstat);
/// then copied into a folder of Visor's own, and that copy, the one that is
/// installed, checked with `codesign --verify --strict --deep` against the
/// requirement of the running app's own identifier and team (from its own
/// designated requirement): a build of another identifier or team, or one
/// changed since it was signed, is refused. What it can't take, it says
/// why, for UpdateKit's `installFailed`; the running app stays.
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

    public static let codesign = "/usr/bin/codesign"
    public static let copy = "/bin/cp"

    let run: Run
    let kind: @Sendable (String) -> Kind

    /// `run` runs the commands (`processes`, or a fake); `kind` says what a
    /// file is (`kind(at:)`, or a fake).
    public init(run: @escaping Run, kind: @escaping @Sendable (String) -> Kind = Self.kind(at:)) {
        self.run = run
        self.kind = kind
    }

    /// The handed-over build at `handedOver` copied into `folder` (a folder
    /// of this app's own, made if it isn't there; a copy left there before
    /// is replaced) and checked against `bundleID` and the team of the
    /// running app at `ownBundle`. A copy that fails its check is removed.
    public func stage(_ handedOver: String, in folder: String, bundleID: String, ownBundle: String) async -> Staged {
        let source = Self.trimmed(handedOver)
        switch kind(source) {
        case .folder: break
        case .link: return .refused("The build Shireworks handed over (\(source)) is a symbolic link, not a folder: it isn't installed")
        case .missing: return .refused("The build Shireworks handed over isn't at \(source)")
        case .other: return .refused("The build Shireworks handed over (\(source)) isn't a folder: it isn't installed")
        }
        guard Self.isIdentifier(bundleID) else { return .refused("This app's bundle id (\(bundleID)) can't be checked against") }
        let own = await run(Self.codesign, ["-d", "-r-", ownBundle])
        guard own.status == 0, let team = Self.team(inRequirement: own.output) else {
            return .refused("This build of Visor names no team in its designated requirement, so no build can be checked against it: "
                            + "the update isn't installed")
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
        let requirement = Self.requirement(bundleID: bundleID, team: team)
        let verified = await run(Self.codesign, ["--verify", "--strict", "--deep", "--test-requirement", "=" + requirement, staged])
        guard verified.status == 0 else {
            try? files.removeItem(atPath: staged)
            return .refused("The build Shireworks handed over failed its signature check (Apple's anchor, \(bundleID), this "
                            + "build's team): " + Self.said(verified))
        }
        return .ready(staged)
    }

    /// The requirement a build to install must meet: Apple's anchor, this
    /// app's identifier, and its team's leaf certificate.
    public static func requirement(bundleID: String, team: String) -> String {
        "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The team a designated requirement names (`certificate
    /// leaf[subject.OU] = <team>`, quoted or not), or nil: an ad hoc
    /// build's names a code hash alone.
    public static func team(inRequirement text: String) -> String? {
        guard let key = text.range(of: "leaf[subject.OU]") else { return nil }
        var rest = text[key.upperBound...].drop { $0 == " " }
        guard rest.first == "=" else { return nil }
        rest = rest.dropFirst().drop { $0 == " " }
        if rest.first == "\"" { rest = rest.dropFirst() }
        let team = String(rest.prefix { $0.isASCII && ($0.isUppercase || $0.isNumber) })
        return team.isEmpty ? nil : team
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

    /// Whether `text` is a bundle id, which goes into the requirement as is.
    static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
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
