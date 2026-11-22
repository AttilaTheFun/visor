// Programs run for the tools (Run) inside Visor's server: each waits on
// threads of its own, never Dispatch's global pool, so many slow ones at
// once (pushes take minutes) leave the pool, and the server's work on it,
// free; and one that runs past its limit is ended.

import Foundation
import Testing
@testable import VisorGHMCP

@Test func manySlowRunsLeaveDispatchsPoolFree() async throws {
    let began = Date()
    let count = 96
    try await withThrowingTaskGroup(of: ProcessResult.self) { group in
        for _ in 0..<count {
            group.addTask { try await Run.run("/bin/sh", ["-c", "sleep 2; echo out; echo err >&2"], timeout: 60) }
        }
        try await Task.sleep(for: .milliseconds(500))
        // While all of them wait, the pool still answers at once.
        let asked = Date()
        await withCheckedContinuation { (answered: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { answered.resume() }
        }
        #expect(Date().timeIntervalSince(asked) < 0.5, "Dispatch's pool is free while \(count) runs wait")
        var finished = 0
        for try await result in group {
            #expect(result.succeeded && result.output == "out" && result.errorText == "err")
            finished += 1
        }
        #expect(finished == count)
    }
    #expect(Date().timeIntervalSince(began) < 20, "they ran side by side")
}

@Test func aRunPastItsLimitIsEnded() async {
    let began = Date()
    // The program itself (exec), as git is: the run ends when it does. (A
    // child of its own that keeps its output open holds the run until it
    // ends too, as in gh_mcp.) SIGTERM first; one that ignores it (here,
    // it may come ignored) is killed 5 s on.
    await #expect(throws: ToolError.self) { try await Run.run("/bin/sh", ["-c", "exec sleep 30"], timeout: 1) }
    #expect(Date().timeIntervalSince(began) < 10)
    let ignoring = Date()
    await #expect(throws: ToolError.self) { try await Run.run("/bin/sh", ["-c", "trap '' TERM; exec sleep 30"], timeout: 1) }
    #expect(Date().timeIntervalSince(ignoring) < 10, "killed once it ignored SIGTERM")
}

@Test func gitIsLookedForWhereGhMCPLookedForIt() {
    // launchd's PATH for a job, then Homebrew's, as gh_mcp's LaunchAgent had it.
    #expect(Git.searchPath("/usr/bin:/bin:/usr/sbin:/sbin") == "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")
    #expect(Git.searchPath("/opt/homebrew/bin:/usr/bin") == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(Git.searchPath(nil) == "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")
}
