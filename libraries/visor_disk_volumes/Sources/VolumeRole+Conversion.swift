// The names a conversion of Sessions or Sources to case-sensitive APFS
// gives its volumes (docs/volume-conversion.md): the copy staged beside
// the role's volume, the old one kept for rollback once the copy is
// swapped in, and a swapped-in copy taken back out by unswap.

extension VolumeRole {
    /// The roles whose volume a person may have made case-insensitive
    /// before Visor Disk Utility did, and so may convert: Sessions and
    /// Sources. Visor's own volume is only ever made by it, case-sensitive.
    public static let convertible: [VolumeRole] = [.sessions, .sources]

    /// Whether it's one of those.
    public var isConvertible: Bool { Self.convertible.contains(self) }

    /// The case-sensitive copy's name while it's staged: `Sessions-new`.
    public var stagedName: String { volumeName + "-new" }

    /// Where the staged copy is mounted: `/Volumes/Sessions-new`.
    public var stagedMountPoint: String { "/Volumes/" + stagedName }

    /// The old, case-insensitive volume's name once the copy is swapped in,
    /// kept unmounted for a rollback: `Sessions-old-ci`.
    public var keptName: String { volumeName + "-old-ci" }

    /// A swapped-in copy's name once unswap has put the old one back:
    /// `Sessions-cs-failed`.
    public var failedName: String { volumeName + "-cs-failed" }

    /// The roles a command line names for a conversion: `sessions`,
    /// `sources`, or `both`; nil for anything else.
    public static func conversionRoles(_ text: String) -> [VolumeRole]? {
        if text == "both" { return convertible }
        guard let role = VolumeRole(rawValue: text), role.isConvertible else { return nil }
        return [role]
    }
}
