import Foundation

// Which requests only read (Logan's container test, 25 Nov 2026: a clone of
// AttilaTheFun/swift_sql failed with no auth token kept). With no token
// configured, a read the gate allows goes on anonymously, as a read outside
// the allowed repositories does (Logan, 9 Nov 2026: public reads need no
// token); GitHub answers a private repository's with 404. Anything else
// still needs the token and is refused without one.
//
// - api.github.com: GET and HEAD, and a GraphQL query (a mutation never is);
// - github.com: a fetch or a clone (`info/refs?service=git-upload-pack`,
//   `POST …/git-upload-pack`), an LFS download, and a release's asset or a
//   ref's archive downloaded. A push (`git-receive-pack`, its `info/refs`
//   too) never is;
// - uploads.github.com: never.

extension GitHubGate {
    /// Whether `request` only reads GitHub: what may go on with no token
    /// when none is configured.
    func isRead(_ request: GateRequest) -> Bool {
        guard let segments = Self.segments(request.path) else { return false }
        let reading = ["GET", "HEAD"].contains(request.method)
        switch request.host.lowercased() {
        case "api.github.com":
            // A GraphQL request the gate lets through as it is, unchecked,
            // is a query: a mutation is always checked or refused.
            if request.method == "POST", segments == ["graphql"] { return decideGraphQL(request) == .allow(repository: nil) }
            return reading
        case "github.com":
            guard segments.count >= 3 else { return false }
            let rest = Array(segments.dropFirst(2))
            if reading, Self.isDownload(rest) { return true }
            switch (request.method, rest) {
            case ("GET", ["info", "refs"]):
                return request.query == "service=git-upload-pack"
            case ("POST", ["git-upload-pack"]):
                return true
            case ("POST", ["info", "lfs", "objects", "batch"]):
                return request.body.flatMap { GateJSON.parse($0)?.object?["operation"]?.string } == "download"
            default:
                return false
            }
        default:
            return false
        }
    }
}
