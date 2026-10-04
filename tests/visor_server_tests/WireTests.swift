// What the server reads and writes itself, the same on every system: the
// WebSocket's handshake and frames, HTTP requests, the digests they and the
// picture names use, pictures' headers, and secrets kept in a file.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

/// A connection's bytes in memory: what the server sent, and a way to say
/// something to it.
@MainActor
private final class MemoryStream: ByteStream {
    var sent = Data()
    var closed = false
    private var reader: (@MainActor (Data?) -> Void)?

    func receive(_ chunk: @escaping @MainActor (Data?) -> Void) { reader = chunk }
    func send(_ data: Data, sent: (@MainActor () -> Void)?) {
        self.sent.append(data)
        sent?()
    }
    func close() { closed = true }
    func arrive(_ data: Data?) { reader?(data) }
}

final class WireTests: ServerTestCase {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    func testDigests() {
        XCTAssertEqual(hex(SHA1.hash(Data("abc".utf8))), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(hex(SHA1.hash(Data())), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(hex(SHA256.hash(Data("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(SHA256.hash(Data())), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(SHA256.hash(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(hex(SHA256.hash(Data(repeating: 0x61, count: 1_000_000))),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    /// A frame as a client sends it: masked.
    private func clientFrame(_ opcode: UInt8, _ payload: [UInt8], final: Bool = true) -> Data {
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        var frame: [UInt8] = [(final ? 0x80 : 0) | opcode]
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8(truncatingIfNeeded: payload.count >> shift)) }
        }
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        return Data(frame)
    }

    func testTheHandshakeAndFrames() {
        let stream = MemoryStream()
        let socket = WebSocketConnection(stream: stream)
        var texts: [String] = []
        var closed = false
        socket.onText = { texts.append($0) }
        socket.onClose = { closed = true }
        socket.start()

        // RFC 6455's own example key, in two pieces.
        stream.arrive(Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n".utf8))
        XCTAssertTrue(stream.sent.isEmpty, "not answered before the head is whole")
        stream.arrive(Data("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
        let answer = String(decoding: stream.sent, as: UTF8.self)
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 101 "))
        XCTAssertTrue(answer.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
        stream.sent = Data()

        // A short message, one with a 16-bit length, and one with a 64-bit
        // length, the last split across arrivals.
        stream.arrive(clientFrame(0x1, Array("hello".utf8)))
        let medium = String(repeating: "m", count: 300)
        stream.arrive(clientFrame(0x1, Array(medium.utf8)))
        let large = String(repeating: "l", count: 70_000)
        let frame = clientFrame(0x1, Array(large.utf8))
        stream.arrive(frame.prefix(5))
        stream.arrive(frame.dropFirst(5))
        XCTAssertEqual(texts, ["hello", medium, large])

        // A message in pieces, a ping between them answered at once.
        stream.arrive(clientFrame(0x1, Array("frag".utf8), final: false))
        stream.arrive(clientFrame(0x9, [1, 2, 3]))
        XCTAssertEqual([UInt8](stream.sent), [0x8A, 3, 1, 2, 3], "the pong, with the ping's payload")
        stream.arrive(clientFrame(0x0, Array("mented".utf8)))
        XCTAssertEqual(texts.last, "fragmented")

        // What the server sends: whole, unmasked, the length as long as it needs.
        stream.sent = Data()
        socket.send(text: "hi")
        XCTAssertEqual([UInt8](stream.sent), [0x81, 2] + Array("hi".utf8))
        stream.sent = Data()
        socket.send(text: large)
        XCTAssertEqual(Array(stream.sent.prefix(2)), [0x81, 127])
        XCTAssertEqual(stream.sent.count, 10 + 70_000)

        // A close is answered and is the end.
        stream.sent = Data()
        stream.arrive(clientFrame(0x8, [0x03, 0xE8]))
        XCTAssertEqual([UInt8](stream.sent), [0x88, 2, 0x03, 0xE8])
        XCTAssertTrue(closed)
        XCTAssertTrue(stream.closed)
    }

    func testANonWebSocketRequestIsRefused() {
        let stream = MemoryStream()
        let socket = WebSocketConnection(stream: stream)
        var closed = false
        socket.onClose = { closed = true }
        socket.start()
        stream.arrive(Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        XCTAssertTrue(String(decoding: stream.sent, as: UTF8.self).hasPrefix("HTTP/1.1 400 "))
        XCTAssertTrue(closed)
    }

    func testAnHTTPRequestIsReadWhenWhole() {
        let head = "POST /api/sessions HTTP/1.1\r\nAuthorization: Bearer pw\r\nContent-Length: 10\r\n\r\n"
        XCTAssertNil(HTTPServer.parse(Data((head + "{\"a\":").utf8)), "the body is not all here")
        let request = HTTPServer.parse(Data((head + "{\"a\":\"b\"}x").utf8))
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/api/sessions")
        XCTAssertEqual(request?.authorization, "pw")
        XCTAssertEqual(request?.body, "{\"a\":\"b\"}x")
        XCTAssertNil(HTTPServer.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)), "the head is not all here")
    }

    func testPicturesAreMeasuredFromTheirHeaders() {
        func be(_ value: Int, _ bytes: Int) -> [UInt8] { (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
        func le(_ value: Int, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + be(13, 4) + Array("IHDR".utf8) + be(1206, 4) + be(2622, 4) + [8, 6, 0, 0, 0]
        XCTAssertEqual(HeaderImageMeasuring.measure(png), ImageSize(width: 1206, height: 2622))
        let gif: [UInt8] = Array("GIF89a".utf8) + le(320, 2) + le(200, 2) + [UInt8](repeating: 0, count: 20)
        XCTAssertEqual(HeaderImageMeasuring.measure(gif), ImageSize(width: 320, height: 200))
        let webp: [UInt8] = Array("RIFF".utf8) + le(100, 4) + Array("WEBPVP8X".utf8) + le(10, 4) + [0, 0, 0, 0] + le(799, 3) + le(599, 3)
        XCTAssertEqual(HeaderImageMeasuring.measure(webp), ImageSize(width: 800, height: 600))
        // A JPEG whose EXIF says it is turned a quarter (orientation 6): its
        // size as shown is its stored one turned.
        let exif: [UInt8] = Array("Exif".utf8) + [0, 0] + Array("MM".utf8) + be(42, 2) + be(8, 4) + be(1, 2)
            + be(0x0112, 2) + be(3, 2) + be(1, 4) + be(6, 2) + [0, 0] + be(0, 4)
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1] + be(exif.count + 2, 2) + exif
            + [0xFF, 0xC0] + be(17, 2) + [8] + be(3024, 2) + be(4032, 2) + [3] + [UInt8](repeating: 0, count: 9)
        XCTAssertEqual(HeaderImageMeasuring.measure(jpeg), ImageSize(width: 3024, height: 4032))
        XCTAssertNil(HeaderImageMeasuring.measure(Array("not a picture at all, just words".utf8)))
    }

    func testSecretsKeptInAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("visor-secrets-\(UUID().uuidString)/secrets.json")
        let secrets = FileSecrets(url: url)
        XCTAssertNil(secrets.get("password"))
        secrets.set("password", "one")
        secrets.set("apns.key", "two")
        XCTAssertEqual(FileSecrets(url: url).get("password"), "one", "read back by another store over the same file")
        secrets.set("password", nil)
        XCTAssertNil(FileSecrets(url: url).get("password"))
        XCTAssertEqual(FileSecrets(url: url).get("apns.key"), "two")
    }
}
