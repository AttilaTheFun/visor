// Surveys of a Mac like the Mini for the conversion's tests: Sessions and
// Sources case-insensitive (40 GB and 120 GB quotas, no reserve), Visor
// case-sensitive, and the same disks staged, swapped and unswapped.

import DiskVolumes
import Foundation

enum ConversionDisks {
    static let sessionsUUID = "11111111-1111-4111-8111-111111111111"
    static let sourcesUUID = "22222222-2222-4222-8222-222222222222"
    static let visorUUID = "33333333-3333-4333-8333-333333333333"
    static let sessionsNewUUID = "44444444-4444-4444-8444-444444444444"
    static let sourcesNewUUID = "55555555-5555-4555-8555-555555555555"

    static let insensitive = "APFS"
    static let sensitive = "Case-sensitive APFS"

    /// The Mini before: disk3 with its system's volumes, Sessions (disk3s7),
    /// Sources (disk3s8) and Visor (disk3s9).
    static func mini(free: Int64 = 408 * ByteSize.gigabyte) -> DiskSurvey {
        let volumes = [
            APFSVolume(device: "disk3s1", name: "Macintosh HD", uuid: "E6D37FA0-1434-405F-9FFD-9B8DF915DD8C", used: 12 * ByteSize.gigabyte,
                       roles: ["System"]),
            APFSVolume(device: "disk3s5", name: "Data", uuid: "FC273B18-B69F-4463-9B9C-A57969691538", used: 200 * ByteSize.gigabyte,
                       roles: ["Data"]),
            APFSVolume(device: "disk3s7", name: "Sessions", uuid: sessionsUUID, used: 3_600_000_000, quota: 40 * ByteSize.gigabyte),
            APFSVolume(device: "disk3s8", name: "Sources", uuid: sourcesUUID, used: 3_100_000_000, quota: 120 * ByteSize.gigabyte),
            APFSVolume(device: "disk3s9", name: "Visor", uuid: visorUUID, used: 1_000_000_000, quota: 200 * ByteSize.gigabyte),
        ]
        let container = APFSContainer(reference: "disk3", uuid: "E182B93B-22B1-46FD-9F5C-2B37E7346D1C", capacity: 994 * ByteSize.gigabyte,
                                      free: free, volumes: volumes)
        return DiskSurvey(bootContainer: "disk3", containers: [container], infos: [
            info("disk3s7", "Sessions", "/Volumes/Sessions", insensitive),
            info("disk3s8", "Sources", "/Volumes/Sources", insensitive),
            info("disk3s9", "Visor", "/Volumes/Visor", sensitive),
        ])
    }

    static func info(_ device: String, _ name: String, _ mountPoint: String?, _ format: String) -> VolumeInfo {
        VolumeInfo(device: device, volumeName: name, mountPoint: mountPoint, filesystemName: format, containerReference: "disk3")
    }

    /// The disks once Stage has made `<Name>-new` for the roles:
    /// Sessions-new disk3s10, Sources-new disk3s11.
    static func staged(_ roles: [VolumeRole] = VolumeRole.convertible) -> DiskSurvey {
        var survey = mini()
        for role in roles {
            let (device, uuid) = role == .sessions ? ("disk3s10", sessionsNewUUID) : ("disk3s11", sourcesNewUUID)
            let quota = role == .sessions ? 40 * ByteSize.gigabyte : 120 * ByteSize.gigabyte
            survey.containers[0].volumes.append(APFSVolume(device: device, name: role.stagedName, uuid: uuid, used: 2_000_000, quota: quota))
            survey.infos.append(info(device, role.stagedName, role.stagedMountPoint, sensitive))
        }
        return survey
    }

    /// The disks once Swap In has run for the roles: the old volume
    /// `<Name>-old-ci`, unmounted, the copy `<Name>` in its place.
    static func swapped(_ roles: [VolumeRole] = VolumeRole.convertible) -> DiskSurvey {
        var survey = staged(roles)
        for role in roles {
            let old = role == .sessions ? "disk3s7" : "disk3s8"
            let new = role == .sessions ? "disk3s10" : "disk3s11"
            rename(&survey, old, to: role.keptName, mountedAt: nil)
            rename(&survey, new, to: role.volumeName, mountedAt: role.mountPoint)
        }
        return survey
    }

    static func rename(_ survey: inout DiskSurvey, _ device: String, to name: String, mountedAt place: String?) {
        for index in survey.containers[0].volumes.indices where survey.containers[0].volumes[index].device == device {
            survey.containers[0].volumes[index].name = name
        }
        for index in survey.infos.indices where survey.infos[index].device == device {
            survey.infos[index].volumeName = name
            survey.infos[index].mountPoint = place
        }
    }

    /// A marker of the role's copy, `minutes` old at `now`.
    static func marker(_ role: VolumeRole, minutesOld minutes: Double = 10, now: Date = ConversionDisks.now) -> ConversionMarker {
        ConversionMarker(role: role, sourceUUID: role == .sessions ? sessionsUUID : sourcesUUID,
                         newUUID: role == .sessions ? sessionsNewUUID : sourcesNewUUID, files: 1204, links: 31, directories: 211,
                         manifestSHA256: String(repeating: "ab", count: 32), sourceListingSHA256: String(repeating: "cd", count: 32),
                         verified: now.addingTimeInterval(-minutes * 60))
    }

    /// A whole second, as the marker's file keeps it.
    static let now = Date(timeIntervalSince1970: 1_795_000_000)
}
