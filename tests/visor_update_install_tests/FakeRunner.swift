import Foundation
import VisorUpdateInstall

/// codesign and cp played: what each is asked, and what it answers. Its cp
/// makes the folder it's asked for, as the real one would.
actor FakeRunner {
    /// The running app's designated requirement, as `codesign -d -r-` says it.
    var ownRequirement = "designated => anchor apple generic and identifier \"com.LoganShire.Visor\" and (certificate "
        + "leaf[field.1.2.840.113635.100.6.1.9] /* exists */ or certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = TEAM000001)"
    var copyStatus: Int32 = 0
    var verifyOutcome = HandedOverBuild.Outcome(status: 0)
    private(set) var calls: [[String]] = []

    func set(ownRequirement: String) { self.ownRequirement = ownRequirement }
    func set(copyStatus: Int32) { self.copyStatus = copyStatus }
    func set(verifyOutcome: HandedOverBuild.Outcome) { self.verifyOutcome = verifyOutcome }

    func run(_ program: String, _ arguments: [String]) -> HandedOverBuild.Outcome {
        calls.append([program] + arguments)
        switch (program, arguments.first) {
        case (HandedOverBuild.codesign, "-d"):
            return HandedOverBuild.Outcome(status: 0, output: "Executable=/Applications/Visor.app/Contents/MacOS/Visor\n" + ownRequirement)
        case (HandedOverBuild.copy, _):
            guard copyStatus == 0, let destination = arguments.last else {
                return HandedOverBuild.Outcome(status: copyStatus, output: "cp: Permission denied")
            }
            try? FileManager.default.createDirectory(atPath: destination + "/Contents/MacOS", withIntermediateDirectories: true)
            return HandedOverBuild.Outcome(status: 0)
        case (HandedOverBuild.codesign, "--verify"):
            return verifyOutcome
        default:
            return HandedOverBuild.Outcome(status: 127, output: "not played: \(program)")
        }
    }

    /// A HandedOverBuild that runs its commands here.
    nonisolated var build: HandedOverBuild {
        HandedOverBuild(run: { program, arguments in await self.run(program, arguments) })
    }
}
