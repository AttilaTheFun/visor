import SwiftUI

/// A QR code's dark modules, as one shape to fill: scaled to the rect it
/// is given, with the four-module quiet zone the standard asks for around
/// it (fill it on a light background).
struct QRCodeShape: Shape {
    let code: QRCode

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let quiet = 4
        let side = min(rect.width, rect.height)
        let module = side / CGFloat(code.size + quiet * 2)
        let origin = CGPoint(x: rect.midX - side / 2 + module * CGFloat(quiet), y: rect.midY - side / 2 + module * CGFloat(quiet))
        for y in 0..<code.size {
            for x in 0..<code.size where code.isDark(x: x, y: y) {
                path.addRect(CGRect(x: origin.x + CGFloat(x) * module, y: origin.y + CGFloat(y) * module, width: module, height: module))
            }
        }
        return path
    }
}
