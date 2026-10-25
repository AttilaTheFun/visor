import Darwin
import Foundation
import VisorServer

/// A Mac's processors and memory, as Mach counts them: every core's ticks
/// together, and the memory in use as Activity Monitor reckons it (the
/// apps', wired and compressed).
public struct MacHostLoad: HostLoadReading {
    public init() {}

    public func sample() -> HostLoadSample? {
        let host = mach_host_self()
        var load = host_cpu_load_info()
        var loadCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let loaded = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(loadCount)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &loadCount) }
        }
        var memory = vm_statistics64()
        var memoryCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let measured = withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(memoryCount)) { host_statistics64(host, HOST_VM_INFO64, $0, &memoryCount) }
        }
        var pageSize: vm_size_t = 0
        guard loaded == KERN_SUCCESS, measured == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let (user, system, idle, nice) = (UInt64(load.cpu_ticks.0), UInt64(load.cpu_ticks.1), UInt64(load.cpu_ticks.2), UInt64(load.cpu_ticks.3))
        let apps = UInt64(memory.internal_page_count) - min(UInt64(memory.internal_page_count), UInt64(memory.purgeable_count))
        let used = (apps + UInt64(memory.wire_count) + UInt64(memory.compressor_page_count)) * UInt64(pageSize)
        return HostLoadSample(busyTicks: user + system + nice, totalTicks: user + system + nice + idle,
                              cpus: ProcessInfo.processInfo.activeProcessorCount, memoryBytes: ProcessInfo.processInfo.physicalMemory,
                              memoryUsedBytes: used)
    }
}
