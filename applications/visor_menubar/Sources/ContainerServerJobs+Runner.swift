import Foundation
import VisorRunner
import VisorServer

extension ContainerServerJobs {
    /// The Runner's container servers (docs/co-tenancy.md): Visor's container
    /// host beside the app's own program, the servers' folders in its data
    /// folder, their jobs labelled with its bundle id.
    static var runner: ContainerServerJobs {
        ContainerServerJobs(
            bundledHost: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/visor-container-host", isDirectory: false).path,
            folders: ServerPlatform.current.host.dataDirectory.appendingPathComponent("container-servers", isDirectory: true),
            labelPrefix: Bundle.main.bundleIdentifier ?? "VisorServer")
    }
}
