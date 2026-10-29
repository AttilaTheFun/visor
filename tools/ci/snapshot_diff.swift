// A snapshot's pixels compared with its kept picture, for CI's proof
// (tools/ci/mac_vm_proof.sh builds this file with swiftc on the runner):
//
//   snapshot_diff <kept.png> <new.png> <diff.png>
//
// Prints how many pixels differ: by more than 24 in a channel, as
// PipelineSnapshots' check counts them, so fonts drawn a hair differently
// count for nothing. Pictures of different sizes are laid over each other
// from the top left, and a pixel only one of them covers differs; a kept
// picture that isn't there (a new screen) differs everywhere. When any
// pixel differs it writes diff.png: the new picture, faded to grey, with
// each differing pixel red.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Pixels {
    var bytes: [UInt8]
    let width: Int
    let height: Int

    /// The picture's RGBA, premultiplied, in a canvas of the given size, from
    /// its top left; nil draws nothing (all clear).
    init(_ image: CGImage?, width: Int, height: Int) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let image else { return }
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // Core Graphics counts from the bottom: the top left is height - image.height up.
            context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
        }
    }
}

func load(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("snapshot_diff: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else { fail("usage: snapshot_diff <kept.png> <new.png> <diff.png>") }
guard let new = load(arguments[2]) else { fail("can't read \(arguments[2])") }
let kept = FileManager.default.fileExists(atPath: arguments[1]) ? load(arguments[1]) : nil
if FileManager.default.fileExists(atPath: arguments[1]), kept == nil { fail("can't read \(arguments[1])") }

let width = max(new.width, kept?.width ?? 0)
let height = max(new.height, kept?.height ?? 0)
let after = Pixels(new, width: width, height: height)
let before = Pixels(kept, width: width, height: height)

var diff = after
var changed = 0
for index in stride(from: 0, to: after.bytes.count, by: 4) {
    var differs = false
    for channel in 0..<4 where abs(Int(after.bytes[index + channel]) - Int(before.bytes[index + channel])) > 24 {
        differs = true
        break
    }
    if differs {
        changed += 1
        diff.bytes.replaceSubrange(index..<index + 4, with: [255, 0, 0, 255])
    } else {
        // Grey, faded two thirds of the way to white: the screen's shapes, behind the red.
        let grey = (Int(after.bytes[index]) * 3 + Int(after.bytes[index + 1]) * 6 + Int(after.bytes[index + 2])) / 10
        let faded = UInt8(255 - (255 - grey) / 3)
        diff.bytes.replaceSubrange(index..<index + 4, with: [faded, faded, faded, 255])
    }
}
print(changed)
guard changed > 0 else { exit(0) }

let data = NSMutableData()
let picture: CGImage? = diff.bytes.withUnsafeMutableBytes { buffer in
    CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
}
guard let picture, let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
    fail("can't make \(arguments[3])")
}
CGImageDestinationAddImage(destination, picture, nil)
guard CGImageDestinationFinalize(destination), data.write(toFile: arguments[3], atomically: true) else { fail("can't write \(arguments[3])") }
