import Foundation
import VisorServer

/// A Linux computer's processors and memory, as /proc says: every core's
/// ticks together (/proc/stat's first line), and the memory not available
/// to programs as the memory in use (/proc/meminfo).
public struct ProcHostLoad: HostLoadReading {
    public init() {}

    public func sample() -> HostLoadSample? {
        guard let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
              let meminfo = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8),
              let line = stat.split(separator: "\n").first(where: { $0.hasPrefix("cpu ") }) else { return nil }
        // user nice system idle iowait irq softirq steal …
        let ticks = line.split(separator: " ").dropFirst().compactMap { UInt64($0) }
        guard ticks.count >= 4 else { return nil }
        let total = ticks.prefix(8).reduce(0, +)
        let waiting = ticks[3] + (ticks.count > 4 ? ticks[4] : 0)
        func kilobytes(_ key: String) -> UInt64? {
            meminfo.split(separator: "\n").first { $0.hasPrefix(key + ":") }.flatMap { line in
                line.split(separator: " ").dropFirst().first.flatMap { UInt64($0) }
            }
        }
        guard let memory = kilobytes("MemTotal") else { return nil }
        let available = kilobytes("MemAvailable") ?? kilobytes("MemFree") ?? 0
        return HostLoadSample(busyTicks: total - min(total, waiting), totalTicks: total, cpus: ProcessInfo.processInfo.activeProcessorCount,
                              memoryBytes: memory * 1024, memoryUsedBytes: (memory - min(memory, available)) * 1024)
    }
}
