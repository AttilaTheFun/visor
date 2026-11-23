// The diskutil commands a conversion's swap and unswap run: a volume
// renamed, unmounted and mounted, each by its disk (`disk3s7`), so no path
// or name can stand for another volume between the commands. VolumeGuard
// passes them only as ConversionPlanner plans them from the disks as they
// are just before they run.

extension DiskCommand {
    /// `diskutil rename <disk> <name>`.
    public static func rename(device: String, to name: String) throws -> DiskCommand {
        try checkDevice(device)
        return DiskCommand(arguments: ["rename", device, name])
    }

    /// `diskutil unmount <disk>` (never `force`: a volume in use stays).
    public static func unmount(device: String) throws -> DiskCommand {
        try checkDevice(device)
        return DiskCommand(arguments: ["unmount", device])
    }

    /// `diskutil mount <disk>`: mounted at `/Volumes/<its name>`.
    public static func mount(device: String) throws -> DiskCommand {
        try checkDevice(device)
        return DiskCommand(arguments: ["mount", device])
    }

    /// Whether a target is an APFS volume's disk, `disk3s7`.
    public static func isVolumeDevice(_ target: String) -> Bool {
        guard target.hasPrefix("disk"), let slice = target.dropFirst(4).firstIndex(of: "s") else { return false }
        let disk = target[target.index(target.startIndex, offsetBy: 4)..<slice], volume = target[target.index(after: slice)...]
        return !disk.isEmpty && !volume.isEmpty && disk.allSatisfy(\.isASCII) && disk.allSatisfy(\.isNumber)
            && volume.allSatisfy(\.isASCII) && volume.allSatisfy(\.isNumber)
    }

    private static func checkDevice(_ device: String) throws {
        guard isVolumeDevice(device) else { throw DiskVolumesError.blocked("\(device) isn't an APFS volume's disk (disk3s7).") }
    }
}
