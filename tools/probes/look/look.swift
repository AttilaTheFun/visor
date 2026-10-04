// What the fixture screens look like, against how they looked when right.
//
//   look shrink <in.png> <out.png> <width>
//       The screenshot at `width` pixels across: what a reference keeps.
//   look compare <shot.png> <reference.png> <diff.png> [percent, default 0.1]
//       Fails (exit 1) when more than `percent` of the pixels differ from the
//       reference by more than a little; the differing pixels are drawn red
//       over a faded copy of the shot in diff.png.
//   look settle <video> <from seconds> <to seconds> [frames, default 3]
//       A page of rows going in: from the first frame after `from` that
//       changes much, counts the frames that differ from the last one — the
//       frames that show the list somewhere other than where it comes to
//       rest. Fails when there are more than `frames`.
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image as RGBA bytes.
struct Pixels {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(_ image: CGImage, width: Int, height: Int) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Whether the pixel at `index` differs in `other` by more than `by`
    /// in any channel.
    func differs(from other: Pixels, at index: Int, by: Int = 32) -> Bool {
        let o = index * 4
        return abs(Int(bytes[o]) - Int(other.bytes[o])) > by || abs(Int(bytes[o + 1]) - Int(other.bytes[o + 1])) > by
            || abs(Int(bytes[o + 2]) - Int(other.bytes[o + 2])) > by
    }

    /// The share of pixels that differ from `other` by more than `by`, in percent.
    func difference(from other: Pixels, by: Int = 32) -> Double {
        var count = 0
        for index in 0..<(width * height) where differs(from: other, at: index, by: by) { count += 1 }
        return Double(count) * 100 / Double(width * height)
    }

    var image: CGImage {
        var copy = bytes
        let context = CGContext(data: &copy, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write("Cannot read \(path)\n".data(using: .utf8)!)
        exit(2)
    }
    return image
}

func save(_ image: CGImage, _ path: String) {
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func shrink(_ args: [String]) {
    let image = load(args[0])
    let width = Int(args[2])!
    let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
    save(Pixels(image, width: width, height: height).image, args[1])
}

func compare(_ args: [String]) {
    let reference = load(args[1])
    let expected = Pixels(reference, width: reference.width, height: reference.height)
    var shot = Pixels(load(args[0]), width: reference.width, height: reference.height)
    // Runs of the same build differ by nothing at all: a change of a few
    // levels is a change.
    let percent = shot.difference(from: expected, by: 8)
    let limit = args.count > 3 ? Double(args[3])! : 0.1
    // Faded, with what differs in red.
    for index in 0..<(shot.width * shot.height) {
        let o = index * 4
        if shot.differs(from: expected, at: index, by: 8) {
            shot.bytes[o] = 255; shot.bytes[o + 1] = 0; shot.bytes[o + 2] = 0
        } else {
            for c in 0..<3 { shot.bytes[o + c] = UInt8(155 + Int(shot.bytes[o + c]) * 100 / 255) }
        }
    }
    save(shot.image, args[2])
    print(String(format: "%.3f%% of pixels differ (limit %.3f%%)", percent, limit))
    exit(percent > limit ? 1 : 0)
}

func settle(_ args: [String]) async throws {
    let asset = AVURLAsset(url: URL(fileURLWithPath: args[0]))
    let from = Double(args[1])!, to = min(Double(args[2])!, try await asset.load(.duration).seconds)
    let limit = args.count > 3 ? Int(args[3])! : 3
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = CGSize(width: 300, height: 650)
    var frames: [Pixels] = []
    var time = from
    while time <= to {
        let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        frames.append(Pixels(image, width: image.width, height: image.height))
        time += 1.0 / 60
    }
    guard let last = frames.last, frames.count > 2 else { print("No frames"); exit(2) }
    // Frames of a recording differ a little everywhere (its compression):
    // a change counts at 8 levels, where a light bubble against the white
    // still shows. The spinner turning is far under 1%.
    let changes = frames.indices.dropFirst().map { frames[$0].difference(from: frames[$0 - 1], by: 8) }
    if ProcessInfo.processInfo.environment["LOOK_DEBUG"] != nil {
        print(changes.enumerated().filter { $0.element > 0.5 }.map { String(format: "%d:%.1f", $0.offset + 1, $0.element) }.joined(separator: " "))
    }
    guard let landed = changes.firstIndex(where: { $0 > 3 }).map({ $0 + 1 }) else {
        print("Nothing went in between \(from) s and \(to) s")
        exit(1)
    }
    let off = frames[landed...].filter { $0.difference(from: last, by: 8) > 1 }.count
    print(String(format: "Rows went in at %.2f s; %d frame(s) showed the list away from where it settled (limit %d)",
                 from + Double(landed) / 60, off, limit))
    exit(off > limit ? 1 : 0)
}

@main
struct Look {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "shrink": shrink(Array(args.dropFirst()))
        case "compare": compare(Array(args.dropFirst()))
        case "settle": try await settle(Array(args.dropFirst()))
        default:
            print("look shrink|compare|settle …")
            exit(2)
        }
    }
}
