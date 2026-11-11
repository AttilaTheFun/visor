import Foundation

/// A file (or folder) of an agent's own that holds part of a conversation,
/// for moving it to another computer: where it is here, and where it goes
/// under the agent's folder there (MigrationFile.place).
package struct ConversationFile: Equatable {
    package var url: URL
    package var place: String
    package var folder: Bool
}
