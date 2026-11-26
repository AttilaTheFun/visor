// A proof's picture of a screen held still: taken until two in a row are
// the same, as the proof's scripts took them before the driver (a caret's
// blink may keep any two from matching: then the last is kept), for as
// long as the proof gives a screen to settle (VISOR_PROOF_SETTLE_SECONDS:
// a slow simulator's sheets and turns outlast a fast one's).

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

    /// How long a screen is given to hold still, in seconds: the test's
    /// VISOR_PROOF_SETTLE_SECONDS, else 5 (the twelve pictures a quarter of
    /// a second apart it was given before, on GitHub's Macs).
    static var settleSeconds: Double {
        guard let seconds = ProcessInfo.processInfo.environment["VISOR_PROOF_SETTLE_SECONDS"].flatMap({ Double($0) }),
              seconds > 0 else { return 5 }
        return seconds
    }

    /// Pictures the screen as `name` (`device` as HeadlessApp.picture
    /// takes it), again until the picture is the same as the one before,
    /// for at most `budget` seconds: how many it took. Records an issue
    /// when no picture comes.
    @discardableResult
    func steadyPicture(_ name: String, device: String? = nil, within budget: Double = HeadlessApp.settleSeconds,
                       sourceLocation: SourceLocation = #_sourceLocation) throws -> Int {
        let deadline = ContinuousClock.now + .milliseconds(Int(budget * 1000))
        var previous: Data?
        var attempt = 0
        repeat {
            attempt += 1
            guard let id = try picture(name, device: device) else {
                Issue.record("no picture of \(name): is the app headful, and its launcher one that takes pictures?",
                             sourceLocation: sourceLocation)
                return attempt
            }
            let picture = try Data(contentsOf: Self.proofFolder.appendingPathComponent("screens/\(id).png"))
            if picture == previous { return attempt }
            previous = picture
            Thread.sleep(forTimeInterval: 0.25)
        } while ContinuousClock.now < deadline
        print("[proof] \(name): never the same twice in \(budget) s, the last picture kept")
        return attempt
    }
}
