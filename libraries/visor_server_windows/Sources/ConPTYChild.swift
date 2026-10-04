import Foundation
import VisorServer
import WinSDK

/// A program attached to a pseudo console: what it draws read from the
/// console's output pipe, what is typed written to its input pipe.
@MainActor
final class ConPTYChild: TerminalChild {
    let processID: Int32
    let output: AsyncStream<Data>
    private(set) var hasExited = false
    private let console: Win32Handle
    private let input: Win32Handle
    private let process: Win32Handle
    private let exit: Task<Void, Never>

    init(_ command: ShellCommand, directory: String, environment: [String: String], cols: Int, rows: Int) throws {
        var inputRead: HANDLE?, inputWrite: HANDLE?, outputRead: HANDLE?, outputWrite: HANDLE?
        guard CreatePipe(&inputRead, &inputWrite, nil, 0).boolValue, CreatePipe(&outputRead, &outputWrite, nil, 0).boolValue,
              let inputRead, let inputWrite, let outputRead, let outputWrite else {
            throw AgentProcessError.spawnFailed("could not make the console's pipes")
        }
        var made: HPCON?
        let size = COORD(X: SHORT(clamping: cols), Y: SHORT(clamping: rows))
        let result = CreatePseudoConsole(size, inputRead, outputWrite, 0, &made)
        // The console has its own copies of its ends.
        CloseHandle(inputRead)
        CloseHandle(outputWrite)
        guard result == 0, let made else {
            CloseHandle(inputWrite)
            CloseHandle(outputRead)
            throw AgentProcessError.spawnFailed("could not make a pseudo console (\(result))")
        }

        // The program is started attached to it.
        var bytes: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &bytes)
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: 16)
        defer { list.deallocate() }
        guard InitializeProcThreadAttributeList(OpaquePointer(list), 1, 0, &bytes).boolValue else {
            ClosePseudoConsole(made)
            throw AgentProcessError.spawnFailed("could not attach to the pseudo console")
        }
        defer { DeleteProcThreadAttributeList(OpaquePointer(list)) }
        // PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
        guard UpdateProcThreadAttribute(OpaquePointer(list), 0, DWORD_PTR(0x0002_0016), made, SIZE_T(MemoryLayout<HPCON>.size), nil, nil).boolValue else {
            ClosePseudoConsole(made)
            throw AgentProcessError.spawnFailed("could not attach to the pseudo console")
        }
        var startup = STARTUPINFOEXW()
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        startup.lpAttributeList = OpaquePointer(list)
        var information = PROCESS_INFORMATION()
        var line = Array(WindowsCommandLine.join([command.executable] + command.arguments).utf16) + [0]
        var block = WindowsCommandLine.environmentBlock(environment)
        // EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT
        let flags = DWORD(0x0008_0000 | 0x0000_0400)
        let created = directory.withCString(encodedAs: UTF16.self) { folder in
            withUnsafeMutablePointer(to: &startup) { pointer in
                pointer.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { info in
                    CreateProcessW(nil, &line, nil, nil, false, flags, &block, folder, info, &information).boolValue
                }
            }
        }
        guard created else {
            let error = GetLastError()
            ClosePseudoConsole(made)
            CloseHandle(inputWrite)
            CloseHandle(outputRead)
            throw AgentProcessError.spawnFailed("\((command.executable as NSString).lastPathComponent) could not be started (error \(error))")
        }
        CloseHandle(information.hThread)
        processID = Int32(bitPattern: information.dwProcessId)
        console = Win32Handle(made)
        input = Win32Handle(inputWrite)
        process = Win32Handle(information.hProcess)
        output = Self.reading(Win32Handle(outputRead))
        let exits = Self.watching(process, console: console, input: input)
        exit = Task { for await _ in exits {} }
        Task { [weak self] in
            await self?.exit.value
            self?.hasExited = true
        }
    }

    /// What the console draws, read on a thread of its own until the
    /// console has closed.
    private nonisolated static func reading(_ pipe: Win32Handle) -> AsyncStream<Data> {
        let (output, drawn) = AsyncStream.makeStream(of: Data.self)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                var read: DWORD = 0
                let count = DWORD(buffer.count)
                let ok = buffer.withUnsafeMutableBytes { ReadFile(pipe.handle, $0.baseAddress, count, &read, nil).boolValue }
                guard ok, read > 0 else { break }
                drawn.yield(Data(buffer[0..<Int(read)]))
            }
            pipe.close()
            drawn.finish()
        }
        return output
    }

    /// The program's exit: waited for on a thread of its own; then the
    /// console closes, which ends its output, and the input with it.
    private nonisolated static func watching(_ process: Win32Handle, console: Win32Handle, input: Win32Handle) -> AsyncStream<Void> {
        let (exits, gone) = AsyncStream.makeStream(of: Void.self)
        Thread.detachNewThread {
            _ = WaitForSingleObject(process.handle, DWORD.max)
            console.close { ClosePseudoConsole($0) }
            input.close()
            process.close()
            gone.finish()
        }
        return exits
    }

    func exited() async {
        await exit.value
    }

    func resize(cols: Int, rows: Int) {
        console.use { _ = ResizePseudoConsole($0, COORD(X: SHORT(clamping: cols), Y: SHORT(clamping: rows))) }
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        input.use { pipe in
            data.withUnsafeBytes { bytes in
                var written: DWORD = 0
                _ = WriteFile(pipe, bytes.baseAddress, DWORD(bytes.count), &written, nil)
            }
        }
    }

    /// Closing the console asks what is attached to it to end; after
    /// `grace` it is given no choice.
    func end(grace: Duration) async {
        guard !hasExited else { return }
        console.close { ClosePseudoConsole($0) }
        let process = self.process
        let force = Task {
            try await Task.sleep(for: grace)
            process.use { _ = TerminateProcess($0, 1) }
        }
        await exit.value
        force.cancel()
    }
}
