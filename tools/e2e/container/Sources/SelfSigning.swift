// The virtualization entitlement for //tools/e2e/container: Bazel's
// command-line programs can't be given entitlements, and a process can't
// take one once it runs. So the program, run as Bazel built it, copies
// itself to a folder of its own, signs the copy ad hoc with
// com.apple.security.virtualization (codesign, which every Mac has), and
// runs it in its place with the same arguments; the copy, signed, goes on.

import Foundation

enum SelfSigning {
    /// Set in the signed copy's environment.
    static let marker = "VISOR_E2E_CONTAINER_SIGNED"

    static let entitlements = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>com.apple.security.virtualization</key>
        \t<true/>
        </dict>
        </plist>

        """

    /// Returns in the signed copy; otherwise signs one, runs it, and exits
    /// with its status.
    static func ensure() {
        guard ProcessInfo.processInfo.environment[marker] == nil else { return }
        let folder = URL(fileURLWithPath: "/tmp/visor-e2e-container-signed-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("container")
        let plist = folder.appendingPathComponent("virtualization.entitlements")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let me = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
            try FileManager.default.copyItem(at: me, to: copy)
            try Data(entitlements.utf8).write(to: plist)
        } catch {
            fail("copying this program to sign it: \(error)")
        }
        guard run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", plist.path, copy.path]) == 0 else {
            fail("codesign couldn't sign \(copy.path) with the virtualization entitlement")
        }
        var environment = ProcessInfo.processInfo.environment
        environment[marker] = "1"
        let status = run(copy.path, Array(CommandLine.arguments.dropFirst()), environment: environment)
        try? FileManager.default.removeItem(at: folder)
        exit(status)
    }

    /// A program run to its end, its output this one's: its status.
    static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        do {
            try process.run()
        } catch {
            fail("\(path): \(error)")
        }
        // Interrupted, the copy is interrupted too, and cleans up.
        signal(SIGINT, SIG_IGN)
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func fail(_ problem: String) -> Never {
        FileHandle.standardError.write(Data("container: \(problem)\n".utf8))
        exit(1)
    }
}
