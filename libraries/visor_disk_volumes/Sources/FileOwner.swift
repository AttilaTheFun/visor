// The person a copy runs as: their user id and groups, what a file copied
// as them can keep of its owner and group.

public struct FileOwner: Equatable, Sendable {
    public var uid: UInt32
    public var groups: Set<UInt32>

    public init(uid: UInt32, groups: Set<UInt32>) {
        self.uid = uid
        self.groups = groups
    }
}
