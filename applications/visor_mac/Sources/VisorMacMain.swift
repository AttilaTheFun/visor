// The program's start: the server agent when asked for (`--server`, the
// launchd job's: MacServerAgent), agent-proxy when asked for
// (`--agent-proxy`, the launchd job's; `agent-proxy …`, its secrets'
// command: MacAgentProxy), else Visor, the app.

@main
enum VisorMacMain {
    @MainActor
    static func main() {
        MacServerAgent.handle(CommandLine.arguments)
        MacAgentProxy.handle(CommandLine.arguments)
        VisorMacApp.main()
    }
}
