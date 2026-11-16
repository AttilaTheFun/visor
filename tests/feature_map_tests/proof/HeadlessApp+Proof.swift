// A proof's picture of a screen held still: taken until two in a row are
// the same, as the proof's scripts took them before the driver (a caret's
// blink may keep any two from matching: then the last is kept).

import Foundation
import IsomerHeadless
import Testing

extension HeadlessApp {
    /// The proof's folder (HeadlessApp.picture's: ISOMER_PROOF, else the
    /// test's outputs' `proof`).
    static var proofFolder: URL {
        let environment = ProcessInfo.processInfo.environment
        return environment["ISOMER_PROOF"].map(URL.init(fileURLWithPath:))
            ?? environment["TEST_UNDECLARED_OUTPUTS_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("proof") }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("isomer-proof")
    }

    /// Pictures the screen as `name` (`device` as HeadlessApp.picture
    /// takes it), again until the picture is the same as the one before,
    /// at most `tries` times: how many it took. Records an issue when no
    /// picture comes.
    @discardableResult
    func steadyPicture(_ name: String, device: String? = nil, tries: Int = 12,
                       sourceLocation: SourceLocation = #_sourceLocation) throws -> Int {
        var previous: Data?
        for attempt in 1...tries {
            guard let id = try picture(name, device: device) else {
                Issue.record("no picture of \(name): is the app headful, and its launcher one that takes pictures?",
                             sourceLocation: sourceLocation)
                return attempt
            }
            let picture = try Data(contentsOf: Self.proofFolder.appendingPathComponent("screens/\(id).png"))
            if picture == previous { return attempt }
            previous = picture
            Thread.sleep(forTimeInterval: 0.25)
        }
        print("[proof] \(name): never the same twice, the last picture kept")
        return tries
    }
}
