// Surveys built from the fixtures, for the tests.

import DiskVolumes
import Foundation

enum Disks {
    static func list(_ plist: String) throws -> [APFSContainer] { try APFSContainer.list(fromPlist: Data(plist.utf8)) }
    static func info(_ plist: String) throws -> VolumeInfo { try VolumeInfo.from(plist: Data(plist.utf8)) }

    /// The VM with its hand-made, case-insensitive Sessions and no Containers.
    static func caseInsensitiveSessions() throws -> DiskSurvey {
        DiskSurvey(bootContainer: "disk3", containers: try list(Fixtures.listWithCaseInsensitiveSessions),
                   infos: [try info(Fixtures.infoCaseInsensitiveSessions)])
    }

    /// The same disks before Sessions was made: neither volume.
    static func fresh() throws -> DiskSurvey {
        var containers = try list(Fixtures.listWithCaseInsensitiveSessions)
        containers[0].volumes.removeAll { $0.name == "Sessions" }
        return DiskSurvey(bootContainer: "disk3", containers: containers)
    }

    /// The VM with both volumes as Visor Disk Utility made them.
    static func both() throws -> DiskSurvey {
        DiskSurvey(bootContainer: "disk3", containers: try list(Fixtures.listWithBoth),
                   infos: [try info(Fixtures.infoSessions), try info(Fixtures.infoVisor)])
    }
}
