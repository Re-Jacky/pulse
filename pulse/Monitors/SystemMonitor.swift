import Foundation
import Combine

final class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0
    @Published var cpuCoreCount: Int = 0
    @Published var cpuChipName: String = ""

    @Published var memUsedGB: Double = 0
    @Published var memTotalGB: Double = 0

    @Published var gpuUsage: Double = 0
    @Published var gpuCoreCount: Int = 0
    @Published var gpuChipName: String = ""

    @Published var processes: [ProcessInfo2] = []

    private let cpuMonitor = CPUMonitor()
    private let memMonitor = MemoryMonitor()
    private let gpuMonitor = GPUMonitor()
    private let processMonitor = ProcessMonitor()
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let cpu = cpuMonitor.read()
        cpuUsage = cpu.usagePercent
        cpuCoreCount = cpu.coreCount
        cpuChipName = cpu.chipName

        let mem = memMonitor.read()
        memUsedGB = mem.usedGB
        memTotalGB = mem.totalGB

        let gpu = gpuMonitor.read()
        gpuUsage = gpu.usagePercent
        gpuCoreCount = gpu.coreCount
        gpuChipName = gpu.chipName

        processes = processMonitor.read()
    }
}
