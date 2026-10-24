import Foundation
import OSSClient

/// The oss server (OS Server, AttilaTheFun/oss) whose machines this
/// server's sessions lease — macOS, Linux and Windows VMs, iOS simulators,
/// Android emulators — through this server, which holds its token.
@MainActor
enum OSSAccess {
    /// A client of the oss at `server` (nil for no URL), through the
    /// platform's HTTP client, with the token as kept at each request.
    static func client(server: String) -> OSSClient? {
        let trimmed = server.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed), url.scheme != nil, url.host != nil else { return nil }
        return OSSClient(server: url, token: { await token() }, transport: PlatformOSSTransport())
    }

    /// oss's token as kept now.
    static func token() -> String { VisorServer.secrets.get("ossToken") ?? "" }
}
