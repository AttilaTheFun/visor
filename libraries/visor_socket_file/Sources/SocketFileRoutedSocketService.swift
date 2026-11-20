/// The host's socket service with a server's socket file beside it: a
/// socket file's channel (SocketFileURL) is opened there, every other by
/// the host's own, as before. Ids are this service's own, each leading to
/// the one that opened it.
import VisorProtocol
import VisorServices

@MainActor
public final class SocketFileRoutedSocketService: VisorSocketService {
    private let socketFile: SocketFileSocketService
    private let other: any VisorSocketService
    /// Each id given out: which service has it, and as what.
    private var opened: [Int32: (service: any VisorSocketService, id: Int32)] = [:]
    private var nextID: Int32 = 1

    public init(socketFile: SocketFileSocketService, other: any VisorSocketService) {
        self.socketFile = socketFile
        self.other = other
    }

    public var sendsHeaders: Bool { other.sendsHeaders }
    public var dropsInBackground: Bool { other.dropsInBackground }

    public func open(url: String) -> Int32 { open(url: url, headers: [:]) }

    public func open(url: String, headers: [String: String]) -> Int32 {
        let service: any VisorSocketService = SocketFileURL.isSocketFile(url) ? socketFile : other
        let inner = service.open(url: url, headers: headers)
        guard inner >= 0 else { return inner }
        let id = nextID
        nextID += 1
        opened[id] = (service, inner)
        return id
    }

    public func send(id: Int32, text: String) {
        guard let (service, inner) = opened[id] else { return }
        service.send(id: inner, text: text)
    }

    public func disconnect(id: Int32) {
        guard let (service, inner) = opened[id] else { return }
        service.disconnect(id: inner)
    }

    public func next(id: Int32) async throws -> String {
        guard let (service, inner) = opened[id] else { throw SocketFileSocketGone() }
        do {
            return try await service.next(id: inner)
        } catch {
            opened[id] = nil
            throw error
        }
    }

    public func delay(milliseconds: Int32) async {
        await other.delay(milliseconds: milliseconds)
    }
}
