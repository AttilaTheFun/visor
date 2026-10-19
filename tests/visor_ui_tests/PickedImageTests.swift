// A picture picked is its own: two picked under the same name (every
// paste is "image-0.png") never share an id, which is their thumbnail's
// key in the image cache.

import Foundation
@testable import VisorUI
import XCTest

final class PickedImageTests: XCTestCase {
    func testTwoPicturesOfOneNameAreTwo() {
        // Two PNGs: the same signature and header length up front, other
        // pixels after.
        let header = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52])
        let first = PickedImage(name: "image-0.png", base64: (header + Data([1, 2, 3])).base64EncodedString())
        let second = PickedImage(name: "image-0.png", base64: (header + Data([4, 5, 6])).base64EncodedString())
        XCTAssertNotEqual(first.id, second.id)
    }
}
