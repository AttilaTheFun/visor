import ClaudeTranscript
import Foundation
import VisorServer
import VisorServerCLI
import WinSDK

/// The command-line server on Windows: its folder in Local AppData, a
/// background run as a process with a hidden console, the console's stop
/// events, and its own program replaced by moving the running one aside.
public struct WindowsSystem: CommandLineSystem {
    public init() {}

    /// %LOCALAPPDATA%\Visor.
    public var dataDirectory: URL {
        let base = WindowsTools.variable("LOCALAPPDATA").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local")
        return base.appendingPathComponent("Visor")
    }

    public var executable: String {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        return length > 0 ? String(decoding: buffer[0..<Int(length)], as: UTF16.self) : CommandLine.arguments[0]
    }

    public func platform(log: @escaping @Sendable (String) -> Void, lifecycle: any ServerLifecycle) -> ServerPlatform {
        let data = dataDirectory
        return ServerPlatform(
            listening: WinsockLoopback(),
            terminals: ConPTYTerminals(),
            processes: WindowsProcessSignals(),
            secrets: FileSecrets(url: data.appendingPathComponent("secrets.json")),
            fetching: FoundationNetworkingFetching(),
            pushSigning: nil,
            images: HeaderImageMeasuring(),
            files: PollingFileWatching(),
            tools: WindowsTools(),
            host: HostDetails(name: ProcessInfo.processInfo.hostName, dataDirectory: data),
            lifecycle: lifecycle,
            exposure: { TailscaleExposure(cli: "C:\\Program Files\\Tailscale\\tailscale.exe") },
            log: log
        )
    }

    /// A new process group with a console of its own that is never shown
    /// (so the agents it starts open no windows), its output and errors
    /// appended to `log`.
    public func startDetached(_ executable: String, _ arguments: [String], log: String) throws -> Int32 {
        var security = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: nil,
                                           bInheritHandle: true)
        // FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL
        let file = log.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(0x0004), DWORD(0x0001 | 0x0002), &security, DWORD(4), DWORD(0x80), nil)
        }
        guard let file, file != HANDLE(bitPattern: -1) else {
            throw NSError(domain: "Visor", code: Int(GetLastError()), userInfo: [NSLocalizedDescriptionKey: "could not open \(log)"])
        }
        defer { CloseHandle(file) }
        var startup = STARTUPINFOW()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        // STARTF_USESTDHANDLES
        startup.dwFlags = DWORD(0x0000_0100)
        startup.hStdOutput = file
        startup.hStdError = file
        var information = PROCESS_INFORMATION()
        var line = Array(WindowsCommandLine.join([executable] + arguments).utf16) + [0]
        // CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW
        let flags = DWORD(0x0000_0200 | 0x0800_0000)
        guard CreateProcessW(nil, &line, nil, nil, true, flags, nil, nil, &startup, &information).boolValue else {
            throw NSError(domain: "Visor", code: Int(GetLastError()), userInfo: [NSLocalizedDescriptionKey: "could not start \(executable)"])
        }
        CloseHandle(information.hThread)
        CloseHandle(information.hProcess)
        return Int32(bitPattern: information.dwProcessId)
    }

    @MainActor
    public func onStop(_ stop: @escaping @Sendable () -> Void) {
        WindowsConsole.onStop(stop)
    }

    /// A running program cannot be written over, but it can be moved: the
    /// running one goes aside (`.old`), the new one takes its name.
    public func install(_ build: String, over executable: String) -> String? {
        let aside = executable + ".old"
        let files = FileManager.default
        try? files.removeItem(atPath: aside)
        do {
            try files.moveItem(atPath: executable, toPath: aside)
        } catch {
            return "Could not move \(executable) aside: \(error.localizedDescription)"
        }
        do {
            try files.copyItem(atPath: build, toPath: executable)
        } catch {
            try? files.moveItem(atPath: aside, toPath: executable)
            return "Could not put \(build) in place of \(executable): \(error.localizedDescription)"
        }
        return nil
    }
}
