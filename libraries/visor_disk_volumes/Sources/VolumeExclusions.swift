// The Visor volume left out of Time Machine and Spotlight, as Nimbus leaves
// its own volume out (Logan, 21 Nov 2026): Visor's data, caches, logs and
// container aren't the person's work, and a container's root filesystem
// would fill a backup disk. Sessions and Sources stay in both: they're what
// is worth backing up.
//
// - Spotlight: `mdutil -i off /Volumes/Visor`, as an administrator, in the
//   same prompt as the volume's creation (VolumeState.createCommands), or
//   again when it's found indexing (exclusionCommands). Read back with
//   `mdutil -s` (as the user).
// - Time Machine: macOS 27 lets no app leave a whole volume out (`tmutil
//   addexclusion -v` is refused to anything an app starts, root or not:
//   Nimbus found it so), so the person adds it in Time Machine's settings
//   (Options… › + › Visor), which Visor Disk Utility opens; read back with
//   `tmutil isexcluded` (as the user).

public struct VolumeExclusions: Equatable, Sendable {
    /// Whether Time Machine leaves it out; nil if unknown.
    public var timeMachineExcluded: Bool?
    /// Whether Spotlight indexes it; nil if unknown.
    public var spotlightIndexed: Bool?

    public init(timeMachineExcluded: Bool?, spotlightIndexed: Bool?) {
        self.timeMachineExcluded = timeMachineExcluded
        self.spotlightIndexed = spotlightIndexed
    }

    /// Both as they should be.
    public var isComplete: Bool { timeMachineExcluded == true && spotlightIndexed == false }

    /// What the card says: "Not backed up by Time Machine · Not indexed by
    /// Spotlight", each part as it is.
    public var summary: String {
        let backup = switch timeMachineExcluded {
        case true?: "Not backed up by Time Machine"
        case false?: "Backed up by Time Machine"
        case nil: "Time Machine unknown"
        }
        let index = switch spotlightIndexed {
        case false?: "Not indexed by Spotlight"
        case true?: "Indexed by Spotlight"
        case nil: "Spotlight unknown"
        }
        return backup + " · " + index
    }

    /// What `tmutil isexcluded <path>` printed: `[Excluded]` or
    /// `[Included]`; nil for anything else.
    public static func timeMachineExcluded(isexcluded output: String) -> Bool? {
        if output.contains("[Excluded]") { return true }
        if output.contains("[Included]") { return false }
        return nil
    }

    /// What `mdutil -s <path>` printed: "Indexing enabled." or "Indexing
    /// disabled." (or "… and the index is disabled"); nil for anything else.
    public static func spotlightIndexed(mdutilStatus output: String) -> Bool? {
        let said = output.lowercased()
        if said.contains("indexing disabled") || said.contains("index is disabled") { return false }
        if said.contains("indexing enabled") { return true }
        return nil
    }
}
