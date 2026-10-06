// The QR codes made here are read back by the system's own reader
// (Vision), at every size a connection code can take: a short address,
// a code of a few hundred bytes, and one past a thousand.

import CoreGraphics
import Vision
@testable import VisorUI
import XCTest

final class QRCodeTests: XCTestCase {
    /// The code drawn as the shape draws it, one module per 8 pixels.
    private func image(_ code: QRCode) throws -> CGImage {
        let scale = 8, quiet = 4
        let side = (code.size + quiet * 2) * scale
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(gray: 0, alpha: 1)
        for y in 0..<code.size {
            for x in 0..<code.size where code.isDark(x: x, y: y) {
                // CoreGraphics' origin is at the bottom: rows flipped.
                context.fill(CGRect(x: (x + quiet) * scale, y: (code.size - 1 - y + quiet) * scale, width: scale, height: scale))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func read(_ code: QRCode) throws -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: try image(code)).perform([request])
        return request.results?.first?.payloadStringValue
    }

    func testTheSystemReadsWhatIsMade() throws {
        let link = "visor://connect?code=" + String(repeating: "eyJob3N0IjoiaHR0cDovLzEwMC45MC40NS4xMTo3NDMzIiwibmFtZSI6", count: 4)
        for (text, expectedVersion) in [("http://10.0.0.5:7433", 2), (link, 10), (String(repeating: "visor-", count: 200), 25)] {
            let code = try XCTUnwrap(QRCode(text), "no code for \(text.count) bytes")
            XCTAssertEqual(code.size, expectedVersion * 4 + 17, "version for \(text.count) bytes")
            XCTAssertEqual(try read(code), text, "read back at \(text.count) bytes")
        }
        // Level M too, which a scanner far from the screen is happier with.
        let medium = try XCTUnwrap(QRCode(link, level: .medium))
        XCTAssertEqual(try read(medium), link)
        // Too long for any version.
        XCTAssertNil(QRCode(String(repeating: "x", count: 3000)))
    }

    func testTheArithmeticUnderneath() {
        // Reed–Solomon: the standard's own check values for version 1-M.
        let data: [UInt8] = [0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11]
        XCTAssertEqual(QRCode.ReedSolomon.remainder(data, degree: 10), [0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55])
        XCTAssertEqual(QRCode.rawDataModules(version: 1), 208)
        XCTAssertEqual(QRCode.rawDataModules(version: 7), 1568)
        XCTAssertEqual(QRCode.dataCapacity(version: 1, level: .low) / 8, 19)
        XCTAssertEqual(QRCode.dataCapacity(version: 10, level: .low) / 8, 274)
        XCTAssertEqual(QRCode.Canvas(version: 7).alignmentPositions(), [6, 22, 38])
        XCTAssertEqual(QRCode.Canvas(version: 32).alignmentPositions(), [6, 34, 60, 86, 112, 138])
    }
}
