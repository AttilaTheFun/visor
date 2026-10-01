// Frames of a video from t0 to t1 at `fps`, laid out in contact sheets,
// each frame labelled with its time.
import AVFoundation
import AppKit
let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1]); let t0 = Double(args[2])!; let t1 = Double(args[3])!
let fps = Double(args[4])!; let out = args[5]
let cols = args.count > 6 ? Int(args[6])! : 6; let perSheet = cols * (args.count > 7 ? Int(args[7])! : 3)
let asset = AVURLAsset(url: url)
let gen = AVAssetImageGenerator(asset: asset)
gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
gen.maximumSize = CGSize(width: 300, height: 650)
var times: [Double] = []; var t = t0; while t <= t1 { times.append(t); t += 1 / fps }
var sheet = 0
for chunk in stride(from: 0, to: times.count, by: perSheet) {
    let batch = Array(times[chunk..<min(times.count, chunk + perSheet)])
    let w = 300, h = 650, rows = (batch.count + cols - 1) / cols
    let image = NSImage(size: NSSize(width: w * cols, height: (h + 24) * rows))
    image.lockFocus()
    NSColor.gray.setFill(); NSRect(x: 0, y: 0, width: w * cols, height: (h + 24) * rows).fill()
    for (i, time) in batch.enumerated() {
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil) else { continue }
        let col = i % cols, row = i / cols
        let x = col * w, y = (rows - 1 - row) * (h + 24)
        NSImage(cgImage: cg, size: NSSize(width: w, height: h)).draw(in: NSRect(x: x, y: y + 24, width: w, height: h))
        (String(format: "%.3fs", time) as NSString).draw(at: NSPoint(x: x + 4, y: y + 4), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.boldSystemFont(ofSize: 14)])
    }
    image.unlockFocus()
    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(out)-\(sheet).png"))
    }
    sheet += 1
}
print("duration", CMTimeGetSeconds(asset.duration), "sheets", sheet)
