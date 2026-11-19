// How diskutil gets an administrator's rights.

/// The way a change to the disks is run as root. The app asks with macOS's
/// own administrator prompt; nothing keeps the password.
enum PrivilegeRoute: Sendable {
    /// macOS's authorization prompt: osascript's `do shell script … with
    /// administrator privileges`, each argument quoted by AppleScript's
    /// `quoted form of`. The prompt is the system's; the app never sees the
    /// password.
    case administratorPrompt
    /// `sudo -n`, never asking: the command line's `--sudo`, for a machine
    /// whose user has passwordless sudo (a leased test VM).
    case sudo

    /// The AppleScript run by osascript with the commands as its arguments:
    /// each quoted, and the `&&` between commands passed through. So no
    /// command's own argument may be exactly `&&`: VolumeGuard refuses one.
    static let script = """
        on run argv
            set commandLine to ""
            repeat with anArgument in argv
                set anArgument to anArgument as text
                if anArgument is "&&" then
                    set commandLine to commandLine & "&& "
                else
                    set commandLine to commandLine & quoted form of anArgument & " "
                end if
            end repeat
            do shell script commandLine with prompt "Visor Disk Utility is changing your Mac's volumes." with administrator privileges
        end run
        """

    /// The command lines to run, one after another, each stopping the rest
    /// if it fails.
    func invocations(of commands: [[String]]) -> [[String]] {
        switch self {
        case .administratorPrompt:
            // One prompt for all of them: joined by && in one shell.
            let joined = commands.enumerated().flatMap { index, argv in index == 0 ? argv : ["&&"] + argv }
            return [["/usr/bin/osascript", "-e", Self.script, "--"] + joined]
        case .sudo:
            return commands.map { ["/usr/bin/sudo", "-n"] + $0 }
        }
    }
}
