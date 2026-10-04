// The Winsock calls, as free functions: inside a type that has a `send`,
// `accept` or `shutdown` of its own, the system's are out of reach by name.

import Foundation
import Synchronization
import WinSDK

/// Winsock started, once per process.
private let started = Mutex(false)

func startWinsock() {
    started.withLock { done in
        guard !done else { return }
        var data = WSADATA()
        _ = WSAStartup(WORD(0x0202), &data)
        done = true
    }
}

/// The value Winsock gives for no socket.
let noSocket = ~SOCKET(0)

/// A TCP socket listening on 127.0.0.1:`port`, or nil with the error.
func listenOnLoopback(_ port: UInt16) -> (socket: SOCKET?, error: Int32) {
    startWinsock()
    let listener = WinSDK.socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP.rawValue))
    guard listener != noSocket else { return (nil, WSAGetLastError()) }
    var address = sockaddr_in()
    address.sin_family = ADDRESS_FAMILY(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { WinSDK.bind(listener, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, WinSDK.listen(listener, SOMAXCONN) == 0 else {
        let error = WSAGetLastError()
        closesocket(listener)
        return (nil, error)
    }
    return (listener, 0)
}

/// The next connection, its writes given up after 30 seconds of a peer
/// that reads nothing; nil when the listener has gone.
func acceptConnection(_ listener: SOCKET) -> SOCKET? {
    let connection = WinSDK.accept(listener, nil, nil)
    guard connection != noSocket else { return nil }
    var patience = DWORD(30_000)
    _ = withUnsafePointer(to: &patience) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<DWORD>.size) {
            setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, $0, Int32(MemoryLayout<DWORD>.size))
        }
    }
    return connection
}

/// Up to `buffer.count` bytes; 0 at the end, less on an error.
func receiveBytes(_ connection: SOCKET, into buffer: inout [UInt8]) -> Int {
    let count = Int32(buffer.count)
    return buffer.withUnsafeMutableBytes { bytes in
        Int(WinSDK.recv(connection, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), count, 0))
    }
}

/// All of `data`, as far as the peer takes it.
func sendAll(_ connection: SOCKET, _ data: Data) {
    data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
        var offset = 0
        while offset < bytes.count {
            let sent = WinSDK.send(connection, base + offset, Int32(bytes.count - offset), 0)
            if sent <= 0 { break }
            offset += Int(sent)
        }
    }
}

/// Ends both directions, waking whoever is blocked on the socket.
func shutdownSocket(_ connection: SOCKET) {
    _ = WinSDK.shutdown(connection, SD_BOTH)
}

func closeSocket(_ connection: SOCKET) {
    _ = closesocket(connection)
}
