// A container's Bazel reads the nearest oss's shared cache (`GET /v1/cache`),
// as oss sets up its own VMs: the home's .bazelrc names the cache, read-only,
// and .netrc holds the read token, where Bazel's HTTP cache takes credentials
// from (not the .bazelrc, which --announce_rc prints). Writing to it is CI's
// alone. The .netrc holds every oss server's read token, under each name a
// build might reach it by (its address in the settings, and the address the
// container reaches it at): the same token reads the files an oss serves on
// that port (`/files/sha256/<hex>`, Xcode's SDK archive among them), which a
// build's downloader config points at. Nothing when there is no oss, or no
// cache on it.

import Foundation
import OSSClient
import VisorProtocol

extension VisorServer {
    /// A container's home's files that reach oss's caches, read-only: the
    /// .bazelrc names the nearest's (the first of `caches`), the .netrc
    /// holds each one's token under each of its names.
    nonisolated static func buildCacheFiles(_ caches: [(hosts: [String], cache: CacheInfo)]) -> [(path: String, data: Data)] {
        guard let nearest = caches.first, let host = nearest.hosts.first else { return [] }
        let rc = """
            # oss's shared Bazel cache, read-only: what CI built is fetched rather
            # than built again here (written by Visor when the container was made).
            build --remote_cache=http://\(host):\(nearest.cache.port)
            build --noremote_upload_local_results

            """
        var named = Set<String>()
        var netrc = ""
        for (hosts, cache) in caches {
            for host in hosts where named.insert(host.lowercased()).inserted {
                netrc += "machine \(host) login bazel password \(cache.readToken)\n"
            }
        }
        return [(".bazelrc", Data(rc.utf8)), (".netrc", Data(netrc.utf8))]
    }

    /// Every oss server's cache that answers, nearest first, as a container
    /// made here reaches it; none without one.
    func buildCacheFiles() async -> [(path: String, data: Data)] {
        guard let pool = ossPool else { return [] }
        let resolve = ServerPlatform.current.host.resolve
        let lan = ServerPlatform.current.host.networkAddresses().first { $0.kind == .lan }?.address
        var caches: [(hosts: [String], cache: CacheInfo)] = []
        for server in await pool.reach() {
            guard let cache = try? await server.client.cache() else { continue }
            let name = server.client.host
            let reached = await Task.detached { Self.leaseHost(oss: name, inContainer: true, lan: lan, resolve: resolve) }.value
            // Where the container reaches it first (the .bazelrc's), then its
            // name in the settings (a MagicDNS name, say, that a downloader
            // config names), unless that is this computer's loopback.
            let loopback = name == "localhost" || name == "::1" || name.hasPrefix("127.")
            caches.append((hosts: loopback || name == reached ? [reached] : [reached, name], cache: cache))
        }
        return Self.buildCacheFiles(caches)
    }
}
