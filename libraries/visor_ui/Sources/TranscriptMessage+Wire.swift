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
        // Pictures are shown; a video is named under the words, as the
        // transcript has no player.
        let pictures = entry.images.indices.filter { AttachmentKind.isImage(entry.images[$0]) }
        let videos = entry.images.filter { !AttachmentKind.isImage($0) }
            .map { (AttachmentKind.isVideo($0) ? "Video: " : "File: ") + AttachmentKind.fileName($0) }
        let text = ([entry.text] + videos).filter { !$0.isEmpty }.joined(separator: "\n")
        self.init(id: id ?? entry.id, role: role, text: text, activities: entry.activities, toolName: entry.toolName,
                  imageURLs: pictures.map { host + "|" + entry.images[$0] },
                  imageSizes: pictures.map { index in
                      index < entry.imageSizes.count
                          ? CGSize(width: CGFloat(entry.imageSizes[index].width), height: CGFloat(entry.imageSizes[index].height))
                          : nil
                  })
    }
}
