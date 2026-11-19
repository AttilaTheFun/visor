// The program's start: a command (DiskUtilityCLI) when given one, else the
// app's window.

@main
enum DiskUtilityMain {
    @MainActor
    static func main() {
        DiskUtilityCLI.handle(CommandLine.arguments)
        DiskUtilityApp.main()
    }
}
