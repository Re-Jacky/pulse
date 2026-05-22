import Foundation

final class MemoryMonitor {
    struct MemoryData {
        let usedGB: Double
        let totalGB: Double
    }

    func read() -> MemoryData {
        let total = Double(ProcessInfo.processInfo.physicalMemory)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return MemoryData(usedGB: 0, totalGB: total / 1_073_741_824)
        }

        let pageSize = Double(vm_kernel_page_size)
        let wired = Double(stats.wire_count) * pageSize
        let active = Double(stats.active_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let used = wired + active + compressed

        return MemoryData(
            usedGB: used / 1_073_741_824,
            totalGB: total / 1_073_741_824
        )
    }
}
