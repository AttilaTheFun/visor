// What this computer is using and for whom (`GET /api/resources`): its
// processors and memory, its sessions' containers, and the machines its
// sessions lease from oss.

import Foundation
import VisorProtocol

extension VisorServer {
    /// How long a reading is good to compare the next with: older, and the
    /// next takes two of its own, `readingGap` apart.
    static let readingFreshness: Duration = .seconds(30)
    static let readingGap: Duration = .milliseconds(500)

    func resources() async -> ServerResources {
        let platform = ServerPlatform.current
        let fresh = { (at: ContinuousClock.Instant?) in at.map { ContinuousClock.now - $0 < Self.readingFreshness } ?? false }
        // A share of processor time is between two readings: with none
        // lately to compare with, one now and the next a moment later.
        if !fresh(resourceReadings.host?.at) || (platform.containers != nil && !fresh(resourceReadings.containersAt)) {
            if let first = platform.load?.sample() { resourceReadings.host = (first, .now) }
            if let runtime = platform.containers { keep(await runtime.stats()) }
            try? await Task.sleep(for: Self.readingGap)
        }

        var host: HostUsage?
        if let now = platform.load?.sample() {
            let percent = resourceReadings.host.flatMap { now.cpuPercent(since: $0.sample) }
            host = HostUsage(name: hostName, cpus: now.cpus, cpuPercent: percent, memoryBytes: Int64(clamping: now.memoryBytes),
                             memoryUsedBytes: Int64(clamping: now.memoryUsedBytes))
            resourceReadings.host = (now, .now)
        }

        var containers: [ContainerUsage] = []
        if let runtime = platform.containers {
            let stats = await runtime.stats()
            let at = ContinuousClock.now
            for stat in stats {
                containers.append(ContainerUsage(id: stat.id, session: sessions.first { $0.info.container?.id == stat.id }?.info.id,
                                                 cpus: stat.cpus, cpuPercent: Self.cpuPercent(stat, since: resourceReadings.containers[stat.id], at: at),
                                                 memoryLimitBytes: stat.memoryLimitBytes.map { Int64(clamping: $0) },
                                                 memoryUsedBytes: stat.memoryUsedBytes.map { Int64(clamping: $0) }))
            }
            keep(stats, at: at)
        }

        let machines = leases.flatMap { session, held in
            held.map { MachineUsage(id: $0.id, platform: $0.platform, config: $0.config, session: session) }
        }.sorted { $0.id < $1.id }
        let note: String? = machines.isEmpty ? nil : "oss does not say yet what each machine is using."
        return ServerResources(sampledAt: Date().timeIntervalSince1970, host: host, containers: containers.sorted { $0.id < $1.id },
                               machines: machines, machinesNote: note)
    }

    private func keep(_ stats: [ContainerStats], at: ContinuousClock.Instant = .now) {
        resourceReadings.containers = Dictionary(stats.map { ($0.id, (cpuMicroseconds: $0.cpuMicroseconds, at: at)) }) { _, last in last }
        resourceReadings.containersAt = at
    }

    /// A container's processors at work since its last reading, 100 for
    /// each core's worth; nil with no reading before, or one from before it
    /// started again.
    static func cpuPercent(_ stat: ContainerStats, since earlier: (cpuMicroseconds: UInt64, at: ContinuousClock.Instant)?,
                           at now: ContinuousClock.Instant) -> Double? {
        guard let earlier, stat.cpuMicroseconds >= earlier.cpuMicroseconds else { return nil }
        let elapsed = (now - earlier.at).components
        let microseconds = Double(elapsed.seconds) * 1_000_000 + Double(elapsed.attoseconds) / 1_000_000_000_000
        guard microseconds > 0 else { return nil }
        return Double(stat.cpuMicroseconds - earlier.cpuMicroseconds) / microseconds * 100
    }
}
