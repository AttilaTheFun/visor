import Foundation
import VisorUpdateInstall

/// cp, codesign and spctl played: what each is asked, and what it answers.
/// Its cp makes the folder it's asked for, as the real one would.
actor FakeRunner {
    var copyStatus: Int32 = 0
    var verifyOutcome = HandedOverBuild.Outcome(status: 0)
    var assessOutcome = HandedOverBuild.Outcome(status: 0)
    private(set) var calls: [[String]] = []

    func set(copyStatus: Int32) { self.copyStatus = copyStatus }
    func set(verifyOutcome: HandedOverBuild.Outcome) { self.verifyOutcome = verifyOutcome }
    func set(assessOutcome: HandedOverBuild.Outcome) { self.assessOutcome = assessOutcome }

    func run(_ program: String, _ arguments: [String]) -> HandedOverBuild.Outcome {
        calls.append([program] + arguments)
        switch program {
        case HandedOverBuild.copy:
            guard copyStatus == 0, let destination = arguments.last else {
                return HandedOverBuild.Outcome(status: copyStatus, output: "cp: Permission denied")
            }
            try? FileManager.default.createDirectory(atPath: destination + "/Contents/MacOS", withIntermediateDirectories: true)
            return HandedOverBuild.Outcome(status: 0)
        case HandedOverBuild.codesign:
            return verifyOutcome
        case HandedOverBuild.spctl:
            return assessOutcome
        default:
            return HandedOverBuild.Outcome(status: 127, output: "not played: \(program)")
        }
    }

    /// A HandedOverBuild that runs its commands here.
    nonisolated var build: HandedOverBuild {
        HandedOverBuild(run: { program, arguments in await self.run(program, arguments) })
    }
}
