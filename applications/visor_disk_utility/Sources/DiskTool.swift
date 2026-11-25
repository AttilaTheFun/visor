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
    /// them against a fresh survey; then the disks as they are after.
    static func change(_ commands: [DiskCommand], route: PrivilegeRoute, fixing: Set<VolumeRole> = []) throws -> DiskSurvey {
        try VolumeGuard.check(commands, against: survey(), user: user, fixing: fixing)
        for invocation in route.invocations(of: commands.map(\.argv)) {
            do {
                _ = try run(invocation)
            } catch let DiskVolumesError.failed(message) where message.contains("(-128)") {
                throw DiskVolumesError.cancelled
            }
        }
        return try survey()
    }

    /// The person running Visor Disk Utility: the owner a volume it makes is
    /// given (chown, in the same prompt).
    static var user: String { NSUserName() }

    /// Who owns the mount point now (its root folder); nil if it can't be
    /// read.
    static func owner(of path: String) -> String? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.ownerAccountName] as? String
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
        let (status, data, said) = try outcome(argv)
        guard status == 0 else {
            let message = String(decoding: said.isEmpty ? data : said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DiskVolumesError.failed(message.isEmpty ? "\(argv[0]) exited with \(status)." : message)
        }
        return data
    }

    /// A program's exit status, standard output and error output, however
    /// it exits.
    static func outcome(_ argv: [String]) throws -> (status: Int32, output: Data, errors: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let output = Pipe()
        // The error output to a file of its own, so a long one never fills
        // a pipe no one reads while the output is read.
        let errorsURL = FileManager.default.temporaryDirectory.appendingPathComponent("visor-disk-utility-\(UUID().uuidString).err")
        guard FileManager.default.createFile(atPath: errorsURL.path, contents: nil),
              let errors = try? FileHandle(forWritingTo: errorsURL) else {
            throw DiskVolumesError.failed("\(argv[0]) couldn't be started: no file for its error output.")
        }
        defer {
            try? errors.close()
            try? FileManager.default.removeItem(at: errorsURL)
        }
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw DiskVolumesError.failed("\(argv[0]) couldn't be started: \(error.localizedDescription)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let said = (try? Data(contentsOf: errorsURL)) ?? Data()
        return (process.terminationStatus, data, said)
    }
}
