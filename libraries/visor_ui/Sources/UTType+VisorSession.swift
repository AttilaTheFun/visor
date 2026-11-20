// A session archive's type (`.visorsession`; docs/protocol.md, "Session
// archive v1"), for File › Import…'s open panel and Export…'s save panel.

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

extension UTType {
    /// A session archive: the type the apps declare for `.visorsession`
    /// (`com.LoganShire.Visor.session`), or the extension's own where none
    /// is declared.
    static var visorSession: UTType { UTType(filenameExtension: "visorsession", conformingTo: .data) ?? .data }
}
