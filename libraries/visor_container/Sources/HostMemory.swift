// How much memory this Mac could give the container now: what's free,
// plus the inactive pages macOS would let go of for it (free_count already
// holds the speculative ones). ContainerSettings sizes the default from it.

import Darwin
import Foundation

public enum HostMemory {
    /// All of it.
    public static var physicalBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Free and reclaimable, in bytes; nil when the kernel won't say.
    public static var availableBytes: UInt64? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
        return pages * UInt64(getpagesize())
    }
}
