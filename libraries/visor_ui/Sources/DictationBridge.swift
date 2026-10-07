import AgentUI
import VisorServices

/// The host's dictation service as the composer's `Dictation`: the one
/// the chat screen hands AgentUI, when the host installed one.
@MainActor
final class DictationBridge: Dictation {
    private let service: any VisorDictationService

    init(_ service: any VisorDictationService) { self.service = service }

    /// The bridge over the installed service, or nil where there is none.
    static var installed: DictationBridge? {
        VisorHost.dictation.map(DictationBridge.init)
    }

    func start(heard: @escaping @MainActor @Sendable (String) -> Void) async throws {
        try await service.start(heard: heard)
    }

    func stop() { service.stop() }
}
