// diskutil, run: read as the user, changed as an administrator.

import DiskVolumes
import Foundation

/// Runs diskutil. Reading the disks (`apfs list`, `info`) needs no rights;
/// a change (`apfs addVolume`, Containers' `apfs deleteVolume`) is checked
/// by VolumeGuard against the disks as they are now, then run through a
/// PrivilegeRoute. Every call blocks: the app makes them off the main
/// actor.
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
        return DiskSurvey(bootContainer: boot, containers: containers, infos: infos, foldersInTheWay: inTheWay)
    }

    /// Runs the commands as an administrator once VolumeGuard has passed
    /// them against a fresh survey; then the disks as they are after.
    static func change(_ commands: [DiskCommand], route: PrivilegeRoute) throws -> DiskSurvey {
        try VolumeGuard.check(commands, against: survey())
        for invocation in route.invocations(of: commands.map(\.argv)) {
            do {
                _ = try run(invocation)
            } catch let DiskVolumesError.failed(message) where message.contains("(-128)") {
                throw DiskVolumesError.cancelled
            }
        }
        return try survey()
    }

    /// volumes.json in Visor's data folder.
    static var statusURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return VolumesStatus.url(inDataDirectory: support.appendingPathComponent("Visor", isDirectory: true))
    }

    /// Writes volumes.json for the survey; the file's path.
    @discardableResult
    static func writeStatus(_ survey: DiskSurvey) throws -> URL {
        let url = statusURL
        try VolumesStatus(survey: survey, updated: Date()).write(to: url)
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
