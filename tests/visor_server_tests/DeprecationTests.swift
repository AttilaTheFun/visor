// What is deprecated (19 Nov 2026) is said in the server's log the first
// time it is used in a run, and never again; and MultiPass's driver name is
// known for what it is.

import Foundation
import Synchronization
@testable import VisorServer
import Testing

extension ServerTests {
@Suite final class DeprecationTests {
    @Test func testEachIsSaidOnceARun() {
        let lines = Mutex<[String]>([])
        let notes = Deprecated.Notes { line in lines.withLock { $0.append(line) } }
        #expect(notes.note(.queuedJob, "a1"))
        #expect(!notes.note(.queuedJob, "a2"), "once")
        #expect(notes.note(.runnerTokens))
        #expect(!notes.note(.runnerTokens, "minted"))
        let said = lines.withLock { $0 }
        #expect(said.count == 2)
        #expect(said[0].hasPrefix("deprecated: agent jobs move to CI") && said[0].hasSuffix("(a1)"))
        #expect(said[1].contains("/api/runners/tokens"))
    }

    @Test func testEveryLineSaysDeprecated() {
        for what in Deprecated.allCases { #expect(what.line.hasPrefix("deprecated: "), "\(what)") }
        #expect(Deprecated.multipassName.line.contains("visor.multipass.internal"))
    }
}
}
