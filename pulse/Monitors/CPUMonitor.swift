import Foundation

final class CPUMonitor {
    struct CPUData {
        let usagePercent: Double
        let coreCount: Int
        let chipName: String
    }

    func read() -> CPUData {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )

        guard result == KERN_SUCCESS, let info = cpuInfo else {
            return CPUData(usagePercent: 0, coreCount: ProcessInfo.processInfo.processorCount, chipName: chipName())
        }

        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        var totalUsage = 0.0
        var coreCount = 0

        for i in 0..<Int(numCPUs) {
            let offset = Int(CPU_STATE_MAX) * i
            let user = Double(info[offset + Int(CPU_STATE_USER)])
            let system = Double(info[offset + Int(CPU_STATE_SYSTEM)])
            let nice = Double(info[offset + Int(CPU_STATE_NICE)])
            let idle = Double(info[offset + Int(CPU_STATE_IDLE)])
            let total = user + system + nice + idle
            if total > 0 {
                totalUsage += (user + system + nice) / total
                coreCount += 1
            }
        }

        let usage = coreCount > 0 ? (totalUsage / Double(coreCount)) * 100.0 : 0.0
        return CPUData(
            usagePercent: min(100, max(0, usage)),
            coreCount: ProcessInfo.processInfo.processorCount,
            chipName: chipName()
        )
    }

    private func chipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let raw = String(cString: brand)
        if raw.isEmpty {
            var modelSize = 0
            sysctlbyname("hw.model", nil, &modelSize, nil, 0)
            var model = [CChar](repeating: 0, count: modelSize)
            sysctlbyname("hw.model", &model, &modelSize, nil, 0)
            return String(cString: model)
        }
        return raw
    }
}
