import Foundation
#if os(iOS)
import os
#endif

/// What the process may still allocate. On iOS the app holds itself to a footprint ceiling well
/// under what the system would allow, so every budget derived from this keeps the whole app
/// beneath it; `FOTUFILM_MEMORY_CEILING_MB` moves the ceiling for tests.
public enum ProcessMemory {
    /// The footprint the app keeps under on iOS: one gigabyte.
    public static var ceilingBytes: Int {
        if let raw = ProcessInfo.processInfo.environment["FOTUFILM_MEMORY_CEILING_MB"],
           let megabytes = Int(raw), megabytes > 0 { return megabytes * 1_000_000 }
        return 1_000_000_000
    }

    /// Bytes left before the ceiling or the system's own limit, whichever is nearer.
    public static func availableBytes() -> Int {
        #if os(iOS)
        let system = Int(os_proc_available_memory())
        let headroom = max(0, ceilingBytes - footprintBytes())
        return system > 0 ? min(system, headroom) : min(512 << 20, headroom)
        #else
        return 8 << 30
        #endif
    }

    /// The process's physical footprint — what the system holds it to.
    public static func footprintBytes() -> Int {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
        #else
        return 0
        #endif
    }
}
