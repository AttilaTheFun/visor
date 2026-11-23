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

    @Test func openFilesAreFoundSpotlightAside() {
        let lsof = """
            COMMAND     PID  USER   FD   TYPE DEVICE SIZE/OFF     NODE NAME
            mds         312  root   12r   DIR   1,18      192        2 /Volumes/Sessions
            mds_store   330  root    4u   REG   1,18    32768       91 /Volumes/Sessions/.Spotlight-V100/Store-V2/x
            mdworker_   880 logan    3r   REG   1,18     2048     1201 /Volumes/Sessions/Claude/a/notes.md
            zsh        4100 logan  cwd    DIR   1,18      320     1500 /Volumes/Sessions/Claude/abc
            claude     4200 logan  cwd    DIR   1,18      320     1500 /Volumes/Sessions/Claude/abc
            claude     4200 logan   21w   REG   1,18     8192     1600 /Volumes/Sessions/Claude/abc/log.jsonl
            """
        let holders = ConversionPreflight.holders(lsof: lsof)
        #expect(holders == ["zsh (4100)", "claude (4200)"])
        #expect(ConversionPreflight.openFilesRefusal(mountPoint: "/Volumes/Sessions", holders: holders)
                == "/Volumes/Sessions has files open by zsh (4100), claude (4200) (lsof /Volumes/Sessions): quit or stop them, "
                + "and try again once lsof lists nothing but Spotlight's.")
        #expect(ConversionPreflight.holders(lsof: "").isEmpty)
        #expect(ConversionPreflight.openFilesRefusal(mountPoint: "/Volumes/Sessions",
                                                     holders: ConversionPreflight.holders(lsof: lsof.split(separator: "\n").prefix(3).joined(separator: "\n"))) == nil)
    }
}
