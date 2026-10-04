import Foundation
import VisorProtocol

/// Terminal sessions: the user's login shell on a terminal, in the
/// session's folder. No models, nothing to resume, no transcript — what is
/// typed and what is drawn go to the one window that has it.
public final class ShellHarness: AgentHarness {
    public let kind = AgentKind.shell
    public let tool: String
    /// The shell each session runs.
    let shell: ShellCommand

    public init(shell: ShellCommand = ToolPath.loginShell()) {
        self.shell = shell
        tool = (shell.executable as NSString).lastPathComponent
    }

    public func catalog() -> AgentCatalog { AgentCatalog(agent: .shell, models: []) }
    @MainActor public func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess { ShellProcess(cwd: cwd, shell: shell) }
    public func resumable(cwd: String) -> [ResumableSession] { [] }
    public func transcript(id: String, cwd: String, limit: Int) -> [TranscriptEntry] { [] }
    public func adoptHistory(id: String, cwd: String) {}
}
