// agent-wrapper: one agent under its harness (Claude Code, or the built-in
// echo), and, when AGENT_DRIVER_URL is set, its line to that driver. It
// reports to its dispatcher (AGENT_DISPATCHER_URL) that the job started,
// then completed or failed, and ends when the agent does: 0 when it
// reported, else 1, so its runner releases the job. WrapperOptions has
// the arguments and environment.

import AgentWrapper
import Foundation

let log: @Sendable (String) -> Void = { FileHandle.standardError.write(Data("agent-wrapper: \($0)\n".utf8)) }

let options: WrapperOptions
do {
    options = try WrapperOptions(arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment)
} catch {
    log("\(error)\n\n\(WrapperOptions.usage)")
    exit(2)
}
let reports = options.dispatcherURL.flatMap {
    DispatcherReports(url: $0, agent: options.agent, runner: options.runner ?? ProcessInfo.processInfo.hostName)
}

let core: AgentCore
do {
    let launch = try HarnessLaunch.for(options.spec, claudeProgram: options.claudeProgram)
    core = AgentCore(agent: options.agent, spec: options.spec, launch: launch, log: log)
    try await core.start()
} catch {
    log("the harness can't start: \(error)")
    try? await reports?.failed(reason: "the harness can't start: \(error)")
    exit(1)
}
log("agent \(options.agent.uuid) started (\(options.spec.harness))")

// Ended by TERM or INT: the agent first.
let signals = [SIGTERM, SIGINT].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { Task { await core.stop() } }
    source.resume()
    return source
}

if let url = options.driverURL {
    guard let link = DriverLink(url: url, core: core, hostName: ProcessInfo.processInfo.hostName, log: log) else {
        log("AGENT_DRIVER_URL isn't http://host:port: \(url)")
        exit(2)
    }
    Task { await link.run() }
    log("driver \(link.host):\(link.port)")
}

// Started, once the harness has a session.
if let reports {
    Task {
        for _ in 0..<600 {
            let session = await core.sessionID
            if !session.isEmpty {
                do { try await reports.started(session: session) } catch { log("the dispatcher didn't take Started: \(error)") }
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

let why = await core.ended()
for source in signals { source.cancel() }
log("agent ended: \(why)")
guard let reports else { exit(0) }
let last = await core.entries.last { $0.role == .assistant && !$0.text.isEmpty }?.text ?? ""
do {
    if why == "the harness ended" || why.hasPrefix("stopped") {
        try await reports.completed(summary: String(last.prefix(500)))
    } else {
        try await reports.failed(reason: why)
    }
    exit(0)
} catch {
    log("the dispatcher didn't take the job's end: \(error)")
    exit(1)
}
