// A container's Bazel reads oss's shared cache (`GET /v1/cache`), as oss
// sets up its own VMs: the home's .bazelrc names the cache, read-only, and
// .netrc holds the read token, where Bazel's HTTP cache takes credentials
// from (not the .bazelrc, which --announce_rc prints). Writing to it is CI's
// alone. Nothing when there is no oss, or no cache on it.

import Foundation
import OSSClient
import VisorProtocol

extension VisorServer {
    /// The two files of a container's home that reach oss's cache at
    /// `host`, read-only.
    nonisolated static func buildCacheFiles(host: String, cache: CacheInfo) -> [(path: String, data: Data)] {
        let rc = """
            # oss's shared Bazel cache, read-only: what CI built is fetched rather
            # than built again here (written by Visor when the container was made).
            build --remote_cache=http://\(host):\(cache.port)
            build --noremote_upload_local_results

            """
        return [(".bazelrc", Data(rc.utf8)), (".netrc", Data("machine \(host) login bazel password \(cache.readToken)\n".utf8))]
    }

    /// oss's cache, as a container made here reaches it; none without one.
    func buildCacheFiles() async -> [(path: String, data: Data)] {
        guard let oss = ossClient, let cache = try? await oss.cache() else { return [] }
        let name = oss.host
        let resolve = ServerPlatform.current.host.resolve
        let lan = ServerPlatform.current.host.networkAddresses().first { $0.kind == .lan }?.address
        let host = await Task.detached { Self.leaseHost(oss: name, inContainer: true, lan: lan, resolve: resolve) }.value
        return Self.buildCacheFiles(host: host, cache: cache)
    }
}
