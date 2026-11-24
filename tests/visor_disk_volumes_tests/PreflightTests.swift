// Before a copy or a swap: Visor's server, app and agents' hosts stopped
// (`ps`), and nothing but Spotlight with a file open on the volume (`lsof`).

import DiskVolumes
import Testing

@Suite struct PreflightTests {
    @Test func visorsProcessesAreFound() {
        let ps = """
              1 /sbin/launchd
            612 /Applications/Visor.app/Contents/MacOS/Visor
            640 /Applications/Visor Disk Utility.app/Contents/MacOS/Visor Disk Utility
            701 /Applications/Visor.app/Contents/Helpers/visor-agent-host
            702 /Users/logan/.local/bin/claude
            900 /tmp/build/Visor.app/Contents/MacOS/Visor
            950 /Applications/Visor Client.app/Contents/MacOS/Visor Client
            """
        let found = ConversionPreflight.visorProcesses(ps: ps)
        #expect(found == ["612 /Applications/Visor.app/Contents/MacOS/Visor", "701 /Applications/Visor.app/Contents/Helpers/visor-agent-host",
                          "900 /tmp/build/Visor.app/Contents/MacOS/Visor"])
        let refusal = ConversionPreflight.serverRefusal(processes: found, portAnswers: false)
        #expect(refusal?.contains("Visor's processes are running (612 ") == true)
        #expect(ConversionPreflight.serverRefusal(processes: [], portAnswers: true)?.contains("answers on 127.0.0.1:7433") == true)
        #expect(ConversionPreflight.serverRefusal(processes: [], portAnswers: false) == nil)
        #expect(ConversionPreflight.visorProcesses(ps: "  1 /sbin/launchd\n 2 /usr/libexec/logd\n").isEmpty)
    }

    /// Apple's Disk Utility open stopped the Mini's first Swap In after its
    /// first rename (24 Nov): swap and unswap refuse while it runs.
    @Test func applesDiskUtilityRunningIsRefused() {
        let open = """
                1 /sbin/launchd
            36015 /System/Applications/Utilities/Disk Utility.app/Contents/MacOS/Disk Utility
              640 /Applications/Visor Disk Utility.app/Contents/MacOS/Visor Disk Utility
            """
        #expect(ConversionPreflight.diskUtilityRefusal(ps: open)?.contains("Apple's Disk Utility is open: quit it first") == true)
        // Visor Disk Utility alone is not Apple's.
        #expect(ConversionPreflight.diskUtilityRefusal(ps: "  640 /Applications/Visor Disk Utility.app/Contents/MacOS/Visor Disk Utility\n") == nil)
        #expect(ConversionPreflight.diskUtilityRefusal(ps: "  1 /sbin/launchd\n") == nil)
    }

    @Test func openFilesAreFoundSpotlightAndTheSystemsFoldersAside() {
        // `lsof -F pcn /Volumes/Sessions`, as root sees it.
        let lsof = """
            p97
            cfseventsd
            f12
            n/Volumes/Sessions/.fseventsd/0000000001a2b3c4
            p312
            cmds
            fcwd
            n/Volumes/Sessions
            p330
            cmds_stores
            f4
            n/Volumes/Sessions/.Spotlight-V100/Store-V2/x
            p880
            cmdworker_shared
            f3
            n/Volumes/Sessions/Claude/a/notes.md
            p4100
            czsh
            fcwd
            n/Volumes/Sessions/Claude/abc
            p4200
            cclaude
            fcwd
            n/Volumes/Sessions/Claude/abc
            f21
            n/Volumes/Sessions/Claude/abc/log.jsonl
            p501
            ccom.apple.Virtualization.VirtualMachine
            f9
            n/Volumes/Sessions/.fseventsdx/not-the-systems
            """
        let holders = ConversionPreflight.holders(lsof: lsof, mountPoint: "/Volumes/Sessions")
        #expect(holders == ["zsh (4100)", "claude (4200)", "com.apple.Virtualization.VirtualMachine (501)"])
        #expect(ConversionPreflight.openFilesRefusal(mountPoint: "/Volumes/Sessions", holders: Array(holders.prefix(2)))
                == "/Volumes/Sessions has files open by zsh (4100), claude (4200) (sudo lsof /Volumes/Sessions): quit or stop them, "
                + "and try again once lsof lists nothing but Spotlight's and the system's own folders'.")
        #expect(ConversionPreflight.holders(lsof: "", mountPoint: "/Volumes/Sessions").isEmpty)
        let systemOnly = lsof.split(separator: "\n").prefix(12).joined(separator: "\n")
        #expect(ConversionPreflight.holders(lsof: systemOnly, mountPoint: "/Volumes/Sessions").isEmpty)
        #expect(ConversionPreflight.openFilesRefusal(mountPoint: "/Volumes/Sessions", holders: []) == nil)
    }
}
