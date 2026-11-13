// The repositories a moved session's runner clones: those its agent worked
// in (edited or wrote files in, or ran git or gh in), not every one its
// conversation named (13 Nov: a session in ~/Developer named twelve).

import Foundation
@testable import VisorServer
import Testing

extension ServerTests {
@Suite final class ProjectSurveyWorkedTests {
    @Test func onlyThePlacesItWorkedInCount() throws {
        let home = "/Users/a"
        let rows: [[String: Any]] = [
            ["type": "user", "message": ["role": "user", "content": "Look at /Users/a/Developer/mentioned/README.md please"]],
            ["type": "assistant", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "name": "Edit", "input": ["file_path": "/Users/a/Developer/edited/Sources/A.swift"]],
                ["type": "tool_use", "name": "Write", "input": ["file_path": "/Users/a/Developer/edited/B.swift"]],
                ["type": "tool_use", "name": "Bash", "input": ["command": "git -C /Users/a/Developer/gitted status"]],
                ["type": "tool_use", "name": "Bash", "input": ["command": "cd /Users/a/Developer/ghed && gh pr list"]],
                ["type": "tool_use", "name": "Bash", "input": ["command": "ls /Users/a/Developer/listed"]],
                ["type": "tool_use", "name": "Read", "input": ["file_path": "/Users/a/Developer/read/C.swift"]],
            ]]],
        ]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("worked-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let worked = ProjectSurvey.workedIn(file, under: home)
        #expect(Set(worked.keys) == ["/Users/a/Developer/edited/Sources", "/Users/a/Developer/edited/B.swift",
                                     "/Users/a/Developer/gitted/status", "/Users/a/Developer/ghed"],
                Comment(rawValue: "\(worked)"))
        #expect(ProjectSurvey.mentions(in: file, under: home).keys.contains("/Users/a/Developer/mentioned/README.md"),
                "a migration still offers what it named")
    }
}
}
