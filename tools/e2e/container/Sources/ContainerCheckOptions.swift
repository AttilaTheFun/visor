// //tools/e2e/container's command line.

import Foundation
import VisorContainerCore

struct ContainerCheckOptions {
    static let usage = """
        usage: container --linux <folder> [--image <ghcr.io/attilathefun/visor-agent@sha256:…>] [--sessions <folder>]
                         [--cpus <n>] [--memory <GiB>] [--keep]

          --linux     Visor's Linux programs (visor-server, relay-client and visor-agent-host links), as
                      Visor.app/Contents/Resources/Linux has them, of a build with `relay-client check`'s health
                      answer (this branch's or later).
          --image     The agent image, by digest (default: /Applications/Visor.app's container.json).
          --sessions  The Sessions volume, shared at the same path (/Volumes/Sessions); a scratch folder is made
                      in it and deleted.
          --cpus      2.  --memory  4 (GiB).
          --keep      Keep the scratch data folder (its logs, the root filesystem) instead of deleting it.
        """

    var linux: URL
    var image: ImageDigest
    var sessions = "/Volumes/Sessions"
    var cpus = 2
    var memoryGiB = 4
    var keep = false

    /// The options, or a problem (and the usage) on standard error and exit 2.
    static func parse(_ arguments: [String]) -> ContainerCheckOptions {
        var linux: URL?
        var image: ImageDigest?
        var options = ContainerCheckOptions(linux: URL(fileURLWithPath: "/"), image: ImageDigest("sha256:" + String(repeating: "0", count: 64))!)
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            if argument == "--keep" {
                options.keep = true
                continue
            }
            guard let value = rest.popFirst() else { fail("\(argument) takes a value") }
            switch argument {
            case "--linux": linux = URL(fileURLWithPath: value, isDirectory: true)
            case "--image":
                guard let digest = ImageDigest(value) else { fail("\(value) isn't the agent image by digest") }
                image = digest
            case "--sessions": options.sessions = value
            case "--cpus":
                guard let n = Int(value), n > 0 else { fail("--cpus takes a count") }
                options.cpus = n
            case "--memory":
                guard let n = Int(value), n > 0 else { fail("--memory takes GiB") }
                options.memoryGiB = n
            default: fail("unknown argument \(argument)")
            }
        }
        guard let linux else { fail("--linux is needed") }
        options.linux = linux
        let installed = ContainerManifest.inResources(URL(fileURLWithPath: "/Applications/Visor.app/Contents/Resources", isDirectory: true))
        guard let chosen = image ?? installed?.image else { fail("--image is needed (no /Applications/Visor.app container.json to take it from)") }
        options.image = chosen
        return options
    }

    static func fail(_ problem: String) -> Never {
        FileHandle.standardError.write(Data("container: \(problem)\n\(usage)\n".utf8))
        exit(2)
    }
}
