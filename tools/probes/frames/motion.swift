// How the thread moves, frame by frame, in a recording of a send: for each
// pair of frames, how far the thread above the composer moved (down is
// positive), found by sliding one frame's strip over the other's. A send
// done right only ever moves the thread up, in small steps; a thread that
// drops as the composer gives up its lines and comes back up as the message
// goes in shows as a step down. Exits 1 when any step down exceeds `limit`
// points.
//
//   motion <video> <from seconds> <to seconds> [limit points, default 6]
import AVFoundation
import AppKit

let args = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let from = Double(args[2])!, to = Double(args[3])!
let limit = args.count > 4 ? Double(args[4])! : 6
let generator = AVAssetImageGenerator(asset: asset)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
let width = 300, height = 650
generator.maximumSize = CGSize(width: width, height: height)

/// A frame as grey bytes, `width` by `height`.
func grey(at time: Double) -> [UInt8]? {
    guard let image = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil) else { return nil }
    var pixels = [UInt8](repeating: 0, count: width * height)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixels
}

// The strip of thread between the navigation bar and where the composer's
// box begins with a few lines typed and the keyboard up.
let top = 70, bottom = 195, reach = 70
/// How far `current` is `previous` moved down (negative: up), in pixels.
func shift(_ previous: [UInt8], _ current: [UInt8]) -> Int {
    func difference(_ d: Int) -> Double {
        var sum = 0, count = 0
        for y in stride(from: top, to: bottom, by: 1) where y - d >= top && y - d < bottom {
            for x in stride(from: 10, to: width - 10, by: 2) {
                sum += abs(Int(current[y * width + x]) - Int(previous[(y - d) * width + x]))
                count += 1
            }
        }
        return count == 0 ? .infinity : Double(sum) / Double(count)
    }
    let still = difference(0)
    guard still > 0.5 else { return 0 }
    var best = 0, least = still
    for d in -reach...reach where d != 0 {
        let value = difference(d)
        if value < least { least = value; best = d }
    }
    // Only a clear match counts as movement.
    return least < still * 0.5 ? best : 0
}

let pointsPerPixel = 874.0 / Double(height)
var previous: [UInt8]?
var worst = 0.0, worstAt = 0.0
var time = from
var line: [String] = []
while time <= to {
    if let frame = grey(at: time) {
        if let previous {
            let moved = Double(shift(previous, frame)) * pointsPerPixel
            if moved != 0 { line.append(String(format: "%.3fs %+.0f", time, moved)) }
            if moved > worst { worst = moved; worstAt = time }
        }
        previous = frame
    }
    time += 1.0 / 30
}
print("steps (points; down is +):", line.isEmpty ? "none" : line.joined(separator: ", "))
print(String(format: "largest step down: %.0f points%@", worst, worst > 0 ? String(format: " at %.3fs", worstAt) : ""))
exit(worst > limit ? 1 : 0)
