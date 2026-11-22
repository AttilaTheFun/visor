import Foundation

/// Git's rules for names, and gh_mcp's for which branches are pushed.
public enum Refs {
    public static var protectedBranches: [String] { Policy.protectedBranches }

    /// A ref name git would take (git check-ref-format's rules), at most 255
    /// bytes; with slashes when `slashes`.
    public static func isValid(_ name: String, slashes: Bool = true) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, name != "@", !name.hasPrefix("-"),
              !name.hasSuffix("/"), !name.hasSuffix("."), !name.hasPrefix("/"),
              !name.contains(".."), !name.contains("//"), !name.contains("@{") else { return false }
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7f { return false }
            if " ~^:?*[\\".unicodeScalars.contains(scalar) { return false }
            if scalar == "/" && !slashes { return false }
        }
        for component in name.split(separator: "/") {
            if component.hasPrefix(".") || component.hasSuffix(".lock") { return false }
        }
        return true
    }

    /// The branch a push names: `name` or `refs/heads/name`, never a tag or
    /// another kind of ref, never main or master.
    public static func pushableBranch(_ input: String) throws -> String {
        var name = input.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("refs/heads/") {
            name.removeFirst("refs/heads/".count)
        } else if name.hasPrefix("refs/") {
            throw ToolError.refused("only branches are pushed (refs/heads/…), never tags or other refs: \(input)")
        }
        guard isValid(name), name != "HEAD" else {
            throw ToolError.invalid("not a branch name git would take: \(input)")
        }
        if protectedBranches.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ToolError.refused("\(name) is never pushed; push a branch of your own and open a pull request")
        }
        return name
    }

    /// A branch, tag or commit to read at: a ref name, or a SHA.
    public static func isReadableRef(_ ref: String) -> Bool {
        isValid(ref)
    }

    /// A remote's name as git takes it (no slashes, nothing odd).
    public static func isRemoteName(_ name: String) -> Bool {
        name != "." && isValid(name, slashes: false)
    }
}
