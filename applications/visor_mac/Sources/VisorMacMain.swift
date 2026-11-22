// The program's start: the server agent when asked for (`--server`, the
// launchd job's: MacServerAgent; `server-agent register|unregister`),
// agent-proxy when asked for (`--agent-proxy`, the launchd job's;
// `agent-proxy …`, its secrets' command: MacAgentProxy), the admin token
// for a script (`admin-token`: MacAdminTokenCommand), its usage for
// `--help` or a command it hasn't (MacCommandLine), else Visor, the app.

@main
enum VisorMacMain {
    @MainActor
    static func main() {
        MacServerAgent.handle(CommandLine.arguments)
        MacAgentProxy.handle(CommandLine.arguments)
        MacAdminTokenCommand.handle(CommandLine.arguments)
        MacCommandLine.handle(CommandLine.arguments)
        VisorMacApp.main()
    }
}
