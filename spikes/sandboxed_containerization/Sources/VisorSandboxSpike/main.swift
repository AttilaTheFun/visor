// Visor sandbox spike: can Apple's Containerization run inside a sandboxed macOS app the way Visor's container
// engine does (libraries/visor_container: ContainerizationMachines)? Ad hoc, sandboxed, run in a leased macOS VM.
//
//   open -a VisorSandboxSpike.app /Volumes/Sessions /Volumes/Sources /Volumes/Visor   -> grant: app-scoped bookmarks
//   open -a VisorSandboxSpike.app --args run                                          -> the spike, from the bookmarks

import AppKit
import Containerization
import ContainerizationArchive
import ContainerizationOCI
import ContainerizationOS
import CryptoKit
import Foundation
import Synchronization
import Virtualization

// MARK: - Logging

let supportDir: URL = {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VisorSandboxSpike", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()
let logURL = supportDir.appendingPathComponent("spike.log")
let logLock = NSLock()

func log(_ line: String) {
    let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
    logLock.lock()
    defer { logLock.unlock() }
    FileHandle.standardError.write(Data(stamped.utf8))
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(stamped.utf8))
        try? handle.close()
    } else {
        try? Data(stamped.utf8).write(to: logURL)
    }
}

func describe(_ error: Error) -> String { "\(error) | \(String(reflecting: error)) | \((error as NSError).domain) \((error as NSError).code)" }

@discardableResult
func step<T>(_ name: String, _ work: () async throws -> T) async -> T? {
    let start = Date()
    log("STEP \(name): start")
    do {
        let value = try await work()
        log("STEP \(name): OK (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
        return value
    } catch {
        log("STEP \(name): FAILED: \(describe(error))")
        return nil
    }
}

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Bookmarks

let bookmarksFile = supportDir.appendingPathComponent("bookmarks.plist")

func saveBookmarks(_ urls: [URL]) {
    var stored = (NSDictionary(contentsOf: bookmarksFile) as? [String: Data]) ?? [:]
    for url in urls {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            stored[url.lastPathComponent] = data
            log("grant: app-scoped bookmark for \(url.path) (\(data.count) bytes)")
        } catch {
            log("grant: bookmark for \(url.path) FAILED: \(describe(error))")
        }
    }
    (stored as NSDictionary).write(to: bookmarksFile, atomically: true)
}

func resolveBookmark(_ name: String) throws -> URL {
    guard let stored = NSDictionary(contentsOf: bookmarksFile) as? [String: Data], let data = stored[name] else {
        throw SpikeError("no bookmark named \(name) in \(bookmarksFile.path)")
    }
    var stale = false
    let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    let started = url.startAccessingSecurityScopedResource()
    log("bookmark \(name): \(url.path), stale \(stale), startAccessingSecurityScopedResource \(started)")
    guard started else { throw SpikeError("startAccessingSecurityScopedResource false for \(url.path)") }
    return url
}

// MARK: - Unix socket echo server (the relay stand-in)

final class EchoServer: @unchecked Sendable {
    let path: String
    let fd: Int32
    init(path: String) throws {
        self.path = path
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SpikeError("socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SpikeError("\(path) is \(bytes.count) bytes: too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0 else { throw SpikeError("bind \(path): \(String(cString: strerror(errno)))") }
        guard listen(fd, 16) == 0 else { throw SpikeError("listen \(path): \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        let thread = Thread { [fd] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                Thread.detachNewThread {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = read(client, &buffer, buffer.count)
                        if n <= 0 { break }
                        let reply = Array("pong:".utf8) + buffer[0..<n]
                        _ = reply.withUnsafeBytes { write(client, $0.baseAddress, reply.count) }
                    }
                    close(client)
                }
            }
        }
        thread.start()
    }

    static func roundTrip(_ path: String, _ message: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) } }
        guard connected == 0 else { throw SpikeError("connect \(path): \(String(cString: strerror(errno)))") }
        let out = Array(message.utf8)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { throw SpikeError("read: \(n)") }
        return String(decoding: buffer[0..<n], as: UTF8.self)
    }
}

// MARK: - Log writer for container processes

final class LogWriter: Writer {
    private let handle: Mutex<FileHandle?>
    init(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let opened = try FileHandle(forWritingTo: url)
        try opened.seekToEnd()
        handle = Mutex(opened)
    }
    func write(_ data: Data) throws { try handle.withLock { try $0?.write(contentsOf: data) } }
    func close() throws {
        let closing = handle.withLock { held -> FileHandle? in defer { held = nil }; return held }
        try closing?.close()
    }
}

// MARK: - Pins (Visor 0.65.1's container.json)

enum Pins {
    static let kernelURL = URL(string: "https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst")!
    static let kernelSHA = "8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5"
    static let kernelMember = "opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug"
    static let initfs = "ghcr.io/apple/containerization/vminit@sha256:c30d5a14c9c25762005363c1736831608806ee8c2a9d8de70dd5439d4812e656"
    static let image = "ghcr.io/attilathefun/visor-agent@sha256:092ad17868052d61f8958d432499a494cbfd61769b4ffc46456a2e849f15a152"
    static let templateGiB: UInt64 = 64
    static let platform = ContainerizationOCI.Platform(arch: "arm64", os: "linux")
}

func hex(_ digest: String) -> String { digest.split(separator: "@").last.map { String($0) }!.replacingOccurrences(of: "sha256:", with: "") }

func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func inventory(_ title: String, _ root: URL, depth: Int = 3) {
    log("INVENTORY \(title): \(root.path)")
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey],
                                                 options: [], errorHandler: { url, error in log("  (unreadable \(url.path): \(error))"); return true })
    else { log("  (no enumerator)"); return }
    for case let url as URL in e {
        if e.level > depth { e.skipDescendants(); continue }
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey])
        let dir = v?.isDirectory == true
        log("  \(url.path.replacingOccurrences(of: root.path, with: "."))\(dir ? "/" : "  size \(v?.fileSize ?? 0) allocated \(v?.totalFileAllocatedSize ?? 0)")")
    }
}

// MARK: - The spike

let teamGroup = Bundle.main.object(forInfoDictionaryKey: "SpikeTeamGroup") as? String ?? "TEAM.com.LoganShire.VisorSpike"
let groupGroup = "group.com.LoganShire.VisorSpike"

func runSpike(skipAssets: Bool = false) async {
    log("==== run: pid \(getpid()), bundle \(Bundle.main.bundleIdentifier ?? "?")")
    let env = ProcessInfo.processInfo.environment
    log("sandbox container id: \(env["APP_SANDBOX_CONTAINER_ID"] ?? "(none: not sandboxed?)")")
    log("NSHomeDirectory: \(NSHomeDirectory())")
    log("temporaryDirectory: \(FileManager.default.temporaryDirectory.path)")
    log("VZVirtualMachine.isSupported: \(VZVirtualMachine.isSupported)")
    var hv: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname("kern.hv_support", &hv, &size, nil, 0)
    log("kern.hv_support: \(hv)")

    // Negative control: the volume before its bookmark is used.
    let pre = "/Volumes/Sessions/pre-bookmark.txt"
    log("negative control: write \(pre) before startAccessing: \(FileManager.default.createFile(atPath: pre, contents: Data("x".utf8)) ? "ALLOWED" : "refused (errno \(errno): \(String(cString: strerror(errno))))")")

    // 1. Group containers.
    var groupRoot: URL?
    for id in [teamGroup, groupGroup] {
        await step("group container \(id.replacingOccurrences(of: teamGroup.components(separatedBy: ".").first ?? "", with: "<team>"))") {
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else { throw SpikeError("containerURL nil") }
            let r = url.appendingPathComponent("r", isDirectory: true)
            try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("hello".utf8).write(to: r.appendingPathComponent("probe.txt"))
            log("  \(url.path) (r/ is \(r.path.utf8.count) bytes)")
            if groupRoot == nil { groupRoot = url }
        }
    }

    // 2. Bookmarks.
    let sessions = await step("bookmark Sessions") { try resolveBookmark("Sessions") }
    let sources = await step("bookmark Sources") { try resolveBookmark("Sources") }
    let visor = await step("bookmark Visor") { try resolveBookmark("Visor") }
    for (name, url) in [("Sessions", sessions), ("Sources", sources), ("Visor", visor)] {
        guard let url else { continue }
        await step("host write+read \(name)") {
            let file = url.appendingPathComponent("host.txt")
            try Data("written by the sandboxed host into \(name)\n".utf8).write(to: file)
            var buf = [UInt8](repeating: 0, count: 256)
            let n = getxattr(file.path, "com.apple.quarantine", &buf, 256, 0, 0)
            log("  \(file.path) quarantine: \(n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : "none")")
            let r = removexattr(file.path, "com.apple.quarantine", 0)
            log("  removexattr quarantine: \(r == 0 ? "removed" : "refused errno \(errno) \(String(cString: strerror(errno)))"), now \(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0) > 0 ? "still quarantined" : "clean")")
            return try String(contentsOf: file, encoding: .utf8)
        }
    }

    // 3. The relay socket in the group container, its host round trip.
    var relayPath: String?
    var servers: [EchoServer] = []
    let socketRoot: URL = {
        if let groupRoot { return groupRoot }
        log("no usable group container: sockets go in the app's own sandbox tmp (Nimbus' place)")
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("r", isDirectory: true)
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return FileManager.default.temporaryDirectory
    }()
    do {
        let groupRoot = socketRoot
        await step("relay socket in \(groupRoot.path)") {
            let path = groupRoot.appendingPathComponent("r/relay.sock").path
            servers.append(try EchoServer(path: path))
            let host = groupRoot.appendingPathComponent("r/h-0123abcd.sock").path
            servers.append(try EchoServer(path: host))
            log("  relay \(path) (\(path.utf8.count) bytes); host socket \(host) (\(host.utf8.count) bytes)")
            let reply = try EchoServer.roundTrip(path, "ping-from-app")
            log("  in-app round trip: \(reply)")
            relayPath = path
        }
    }

    // 4. The assets, in Visor's layout on the Visor volume (Containers/).
    guard let visor else { log("no Visor volume: stopping"); return }
    let root = visor.appendingPathComponent("Containers", isDirectory: true)
    let kernel = root.appendingPathComponent("kernel/vmlinux")
    let storeURL = root.appendingPathComponent("store", isDirectory: true)
    let initfsURL = storeURL.appendingPathComponent("initfs/\(hex(Pins.initfs)).ext4")
    let template = root.appendingPathComponent("templates/\(hex(Pins.image))-\(Pins.templateGiB).ext4")
    let rootfs = root.appendingPathComponent("sessions/rootfs.ext4")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    await step("kernel (download, sha256, extract)") {
        if FileManager.default.fileExists(atPath: kernel.path) { log("  kept"); return }
        let (file, response) = try await URLSession.shared.download(from: Pins.kernelURL)
        log("  downloaded to \(file.path) (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
        let found = try sha256(of: file)
        guard found == Pins.kernelSHA else { throw SpikeError("sha256 \(found)") }
        let reader = try ArchiveReader(file: file)
        let (_, data) = try reader.extractFile(path: Pins.kernelMember)
        try FileManager.default.createDirectory(at: kernel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: kernel)
        try? FileManager.default.removeItem(at: file)
        log("  vmlinux \(data.count) bytes")
    }
    let store = await step("ImageStore at Visor/Containers/store") { try ImageStore(path: storeURL) }
    guard let store else { return }
    await step("pull + unpack vminit") {
        let image = try await store.get(reference: Pins.initfs, pull: true)
        if FileManager.default.fileExists(atPath: initfsURL.path) { log("  kept"); return }
        try FileManager.default.createDirectory(at: initfsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await InitImage(image: image).initBlock(at: initfsURL, for: .linuxArm)
    }
    await step("pull + unpack visor-agent") {
        let image = try await store.get(reference: Pins.image, pull: true)
        if !FileManager.default.fileExists(atPath: template.path) {
            try FileManager.default.createDirectory(at: template.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try await EXT4Unpacker(capacityInBytes: Pins.templateGiB << 30).unpack(image, for: Pins.platform, at: template)
        }
        try FileManager.default.createDirectory(at: rootfs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: rootfs)
        try FileManager.default.copyItem(at: template, to: rootfs)  // clonefile on APFS
    }
    inventory("Visor/Containers", root)
    inventory("sandbox tmp", FileManager.default.temporaryDirectory)
    inventory("sandbox Library/Caches", FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0], depth: 2)

    // 5. Boot, as ContainerizationMachines.boot does.
    guard let sessions, let sources else { return }
    let sessionsLog = root.appendingPathComponent("sessions/logs", isDirectory: true)
    let container = await step("boot (create + start)") { () -> LinuxContainer in
        let vmm = VZVirtualMachineManager(kernel: Kernel(path: kernel, platform: .linuxArm),
                                          initialFilesystem: .block(format: "ext4", source: initfsURL.path, destination: "/", options: ["ro"]))
        var config = LinuxContainer.Configuration()
        let image = try await store.get(reference: Pins.image)
        if let imageConfig = try await image.config(for: Pins.platform).config {
            config.process = LinuxProcessConfiguration(from: imageConfig)
        }
        config.process.user = ContainerizationOCI.User()
        config.process.arguments = ["/bin/sh", "-c", "echo main-up; sleep 3600"]
        let main = try LogWriter(sessionsLog.appendingPathComponent("main.log"))
        config.process.stdout = main
        config.process.stderr = main
        config.interfaces = []
        if let relayPath {
            config.sockets = [UnixSocketConfiguration(source: URL(fileURLWithPath: relayPath),
                                                      destination: URL(fileURLWithPath: "/run/agent-proxy/relay.sock"), direction: .into)]
        }
        config.mounts.append(.share(source: sessions.path, destination: sessions.path, options: []))
        config.mounts.append(.share(source: sources.path, destination: sources.path, options: []))
        config.cpus = 2
        config.memoryInBytes = 2 << 30
        config.hostname = "spike"
        config.useInit = true
        config.bootLog = .file(path: root.appendingPathComponent("sessions/boot.log"), append: false)
        let c = try LinuxContainer("spike", rootfs: .block(format: "ext4", source: rootfs.path, destination: "/"), vmm: vmm,
                                   vm: VMResources(cpus: 2, memoryInBytes: (2 << 30) + VMResources.guestMemoryOverhead), configuration: config)
        try await c.create()
        do { try await c.start() } catch { try? await c.stop(); throw error }
        return c
    }
    guard let container else {
        inventory("sandbox tmp after boot", FileManager.default.temporaryDirectory)
        log("==== run: done (no boot)")
        return
    }

    // 6. Exec: the shares both ways, and the relay socket from the guest.
    func exec(_ id: String, _ script: String) async throws -> Int32 {
        var p = LinuxProcessConfiguration()
        p.arguments = ["/bin/sh", "-c", script]
        p.user = ContainerizationOCI.User()
        let out = try LogWriter(sessionsLog.appendingPathComponent("\(id).log"))
        p.stdout = out
        p.stderr = out
        let proc = try await container.exec(id, configuration: p)
        try await proc.start()
        let status = try await proc.wait()
        try? await proc.delete()
        let text = (try? String(contentsOf: sessionsLog.appendingPathComponent("\(id).log"), encoding: .utf8)) ?? ""
        log("  exec \(id) exit \(status.exitCode):\n\(text)")
        return status.exitCode
    }
    await step("exec: virtiofs shares read+write") {
        _ = try await exec("shares", """
            uname -a; mount | grep -E 'virtiofs|Volumes' ;
            cat \(sessions.path)/host.txt \(sources.path)/host.txt &&
            echo "written by the guest" > \(sessions.path)/guest.txt && echo "written by the guest" > \(sources.path)/guest.txt && echo GUEST-WROTE
            """)
        for url in [sessions, sources] {
            log("  host reads \(url.path)/guest.txt: \((try? String(contentsOf: url.appendingPathComponent("guest.txt"), encoding: .utf8)) ?? "MISSING")")
        }
    }
    await step("exec: relay socket round trip from the guest") {
        _ = try await exec("relay", """
            ls -l /run/agent-proxy/;
            if command -v python3 >/dev/null; then python3 -c 'import socket;s=socket.socket(socket.AF_UNIX);s.connect("/run/agent-proxy/relay.sock");s.sendall(b"ping-from-guest");print(s.recv(100).decode())';
            elif command -v socat >/dev/null; then printf ping-from-guest | socat -t2 - UNIX-CONNECT:/run/agent-proxy/relay.sock; echo;
            else printf ping-from-guest | nc -U -w2 /run/agent-proxy/relay.sock; echo; fi
            """)
    }
    await step("stop") { try await container.stop() }
    inventory("sandbox tmp after boot", FileManager.default.temporaryDirectory)
    log("==== run: done")
}

// MARK: - App

final class Delegate: NSObject, NSApplicationDelegate {
    var opened: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        log("grant: opened \(urls.map(\.path))")
        saveBookmarks(urls)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        log("launched: \(args)")
        if args.contains("run") {
            Task {
                await runSpike()
                // Keep listening for an outside nc -U round trip if asked.
                if args.contains("linger") { try? await Task.sleep(for: .seconds(180)) }
                exit(0)
            }
        } else if args.contains("panel") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            panel.directoryURL = URL(fileURLWithPath: "/Volumes")
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK { saveBookmarks(panel.urls) }
            exit(0)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
        }
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
