// A picture is decoded once, off the main actor, no larger than it is
// drawn: a screenshot shown as a thumbnail is a thumbnail's worth of
// pixels, not the screenshot's, and drawing it is only drawing.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import VisorUI
import XCTest

final class DecodedPictureTests: XCTestCase {
    /// A PNG of `width` by `height`, base64, as the computer sends it.
    private func png(width: Int, height: Int) throws -> String {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (data as Data).base64EncodedString()
    }

    func testAThumbnailIsDecodedAtItsDrawnSize() async throws {
        let screenshot = try png(width: 1206, height: 2622)
        let decoded = await DecodedPicture.decode(base64: screenshot, maxEdge: 220, scale: 3)
        let picture = try XCTUnwrap(decoded)
        XCTAssertEqual(picture.size, CGSize(width: 1206, height: 2622), "the picture's own size, for the reserved frame")
        XCTAssertEqual(max(picture.image.width, picture.image.height), 660, "220 points at 3x, not 2622 pixels")
    }

    func testUnboundedIsTheWholePicture() async throws {
        let bytes = try png(width: 640, height: 480)
        let decoded = await DecodedPicture.decode(base64: bytes, maxEdge: 0, scale: 2)
        let picture = try XCTUnwrap(decoded)
        XCTAssertEqual(picture.image.width, 640)
        XCTAssertEqual(picture.image.height, 480)
    }

    func testASmallPictureIsNotEnlarged() async throws {
        let bytes = try png(width: 40, height: 30)
        let decoded = await DecodedPicture.decode(base64: bytes, maxEdge: 220, scale: 3)
        let picture = try XCTUnwrap(decoded)
        XCTAssertEqual(picture.image.width, 40)
    }

    func testBytesThatAreNotAPictureAreNothing() async {
        let none = await DecodedPicture.decode(base64: "not a picture", maxEdge: 220, scale: 3)
        XCTAssertNil(none)
    }
}
