import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

extension TranscriptMessage {
    /// `host` because a picture is a file on that computer: the reference
    /// carries which one, so the transcript's image hook knows where to ask.
    /// `id`: the id to show it under (the transcript's display id), when
    /// not the row's own.
    init(_ entry: TranscriptEntry, host: String = "", id: String? = nil) {
        let role: TranscriptMessage.Role
        switch entry.role {
        case .user: role = .user
        case .assistant: role = .assistant
        case .tool: role = .tool
        }
        // Every attachment is a tile: a picture drawn, a video or a file
        // named (VisorImage), each opened whole by the system's preview.
        self.init(id: id ?? entry.id, role: role, text: entry.text, activities: entry.activities, toolName: entry.toolName,
                  imageURLs: entry.images.map { host + "|" + $0 },
                  imageSizes: entry.images.indices.map { index in
                      index < entry.imageSizes.count && AttachmentKind.isImage(entry.images[index])
                          ? CGSize(width: CGFloat(entry.imageSizes[index].width), height: CGFloat(entry.imageSizes[index].height))
                          : nil
                  })
    }
}
