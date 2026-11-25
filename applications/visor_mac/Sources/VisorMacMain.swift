// The program's start: the app's own launchd agent's command (`app-agent
// start|unregister`: MacAppInstance), the server agent when asked for
// (`--server`, the launchd job's until 0.72.1, kept a release for the
// hand-back: MacServerAgent; `server-agent register`), agent-proxy when
// asked for (`--agent-proxy`, the launchd job's; `agent-proxy …`, its
// secrets' command: MacAgentProxy), the admin token for a script
// (`admin-token`: MacAdminTokenCommand), its usage for `--help` or a
// command it hasn't (MacCommandLine); else Visor, the app, once it's the
// only one (MacAppInstance.settle).

@main
enum VisorMacMain {
    @MainActor
    static func main() {
        MacAppInstance.handle(CommandLine.arguments)
        MacServerAgent.handle(CommandLine.arguments)
        MacAgentProxy.handle(CommandLine.arguments)
        MacAdminTokenCommand.handle(CommandLine.arguments)
        MacCommandLine.handle(CommandLine.arguments)
        MacAppInstance.settle(CommandLine.arguments)
        VisorMacApp.main()
    }
}
