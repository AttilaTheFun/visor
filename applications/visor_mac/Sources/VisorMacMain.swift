// The program's start: agent-proxy when asked for (`--agent-proxy`, the
// launchd job's; `agent-proxy …`, its secrets' command: MacAgentProxy),
// else Visor, the app.

@main
enum VisorMacMain {
    @MainActor
    static func main() {
        MacAgentProxy.handle(CommandLine.arguments)
        VisorMacApp.main()
    }
}
