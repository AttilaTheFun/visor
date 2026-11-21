// diskutil, run: read as the user, changed as an administrator.

import DiskVolumes
import Foundation

/// Runs diskutil. Reading the disks (`apfs list`, `info`) needs no rights;
/// a change (`apfs addVolume`) is checked by VolumeGuard against the disks
/// as they are now, then run through a PrivilegeRoute. Every call blocks:
/// the app makes them off the main actor.
enum DiskTool {
    /// What diskutil says of the disks now.
    static func survey() throws -> DiskSurvey {
        let root = try VolumeInfo.from(plist: run([DiskCommand.diskutil, "info", "-plist", "/"]))
        guard let boot = root.containerReference else {
            throw DiskVolumesError.blocked("The boot disk isn't APFS.")
        }
        let containers = try APFSContainer.list(fromPlist: run([DiskCommand.diskutil, "apfs", "list", "-plist"]))
        var infos: [VolumeInfo] = []
        for device in DiskSurvey.devicesToDescribe(in: containers) {
            infos.append(try VolumeInfo.from(plist: run([DiskCommand.diskutil, "info", "-plist", device])))
        }
        var inTheWay: Set<String> = []
        for role in VolumeRole.allCases where !infos.contains(where: { $0.mountPoint == role.mountPoint }) {
            if DiskVolumes.isMountPoint(role.mountPoint) {
                // Something else is mounted there (another disk's volume).
                infos.append(try VolumeInfo.from(plist: run([DiskCommand.diskutil, "info", "-plist", role.mountPoint])))
            } else if FileManager.default.fileExists(atPath: role.mountPoint) {
                inTheWay.insert(role.mountPoint)
            }
        }
        var freeSpace: [String: Int64] = [:]
        for mountPoint in infos.compactMap(\.mountPoint) {
            let free = (try? FileManager.default.attributesOfFileSystem(forPath: mountPoint))?[.systemFreeSize] as? NSNumber
            freeSpace[mountPoint] = free?.int64Value
        }
        return DiskSurvey(bootContainer: boot, containers: containers, infos: infos, foldersInTheWay: inTheWay, freeSpace: freeSpace)
    }

    /// Runs the commands as an administrator once VolumeGuard has passed
    /// them against a fresh survey and volumes.json's record of Visor's own
    /// volumes; then the disks as they are after.
    static func change(_ commands: [DiskCommand], route: PrivilegeRoute, deleting: Set<VolumeRole> = []) throws -> DiskSurvey {
        try VolumeGuard.check(commands, against: survey(), recorded: DiskVolumes.readStatus(at: statusURL), deleting: deleting)
        for invocation in route.invocations(of: commands.map(\.argv)) {
            do {
                _ = try run(invocation)
            } catch let DiskVolumesError.failed(message) where message.contains("(-128)") {
                throw DiskVolumesError.cancelled
            }
        }
        return try survey()
    }

    /// Whether the Visor volume at `path` is left out of Time Machine and
    /// Spotlight, as tmutil and mdutil say (as the user: they only read).
    static func exclusions(at path: String = VolumeRole.visor.mountPoint) -> VolumeExclusions {
        func said(_ argv: [String]) -> String {
            (try? run(argv)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        return VolumeExclusions(timeMachineExcluded: VolumeExclusions.timeMachineExcluded(isexcluded: said(["/usr/bin/tmutil", "isexcluded", path])),
                                spotlightIndexed: VolumeExclusions.spotlightIndexed(mdutilStatus: said([DiskCommand.mdutil, "-s", path])))
    }

    /// Time Machine's settings, where the person leaves the Visor volume
    /// out (Options… › + › Visor): no app may (VolumeExclusions).
    static let timeMachineSettings = URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")

    /// volumes.json in Visor's data folder: on the Visor volume once it's
    /// there (VisorFolders), else in Application Support, as before.
    static var statusURL: URL { VolumesStatus.url(inDataDirectory: VisorFolders.locate().data) }

    /// The Sessions container's folder on the Visor volume emptied: its
    /// image, root filesystem, caches and logs, all made again when it next
    /// starts. A folder of this user's, so no administrator is asked; the
    /// volume, which holds Visor's data too, is never erased. What was
    /// removed (the folder's path); nil when there was nothing to remove.
    static func clearContainers() throws -> String? {
        guard let folder = VisorFolders.locate().containers else {
            throw DiskVolumesError.blocked("There's no Visor volume at \(VolumeRole.visor.mountPoint), so no container's folder on it.")
        }
        let files = FileManager.default
        guard files.fileExists(atPath: folder.path) else { return nil }
        for name in try files.contentsOfDirectory(atPath: folder.path) {
            try files.removeItem(at: folder.appendingPathComponent(name))
        }
        return folder.path
    }

    /// Writes volumes.json for the survey, keeping the UUIDs of Visor's own
    /// volumes the last one recorded; the file's path.
    @discardableResult
    static func writeStatus(_ survey: DiskSurvey) throws -> URL {
        let url = statusURL
        try VolumesStatus(survey: survey, updated: Date(), previous: DiskVolumes.readStatus(at: url)).write(to: url)
        return url
    }

    /// A program's standard output; throws with its error output if it fails.
    static func run(_ argv: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw DiskVolumesError.failed("\(argv[0]) couldn't be started: \(error.localizedDescription)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let said = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: said.isEmpty ? data : said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DiskVolumesError.failed(message.isEmpty ? "\(argv[0]) exited with \(process.terminationStatus)." : message)
        }
        return data
    }
}
