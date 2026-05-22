import Foundation
import IOKit

final class GPUMonitor {
    struct GPUData {
        let usagePercent: Double
        let coreCount: Int
        let chipName: String
    }

    func read() -> GPUData {
        var iterator: io_iterator_t = 0
        let matchingDict = IOServiceMatching("IOAccelerator")

        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS else {
            return GPUData(usagePercent: 0, coreCount: 0, chipName: "GPU")
        }
        defer { IOObjectRelease(iterator) }

        var bestUsage = 0.0
        var chipName = "GPU"

        var service: io_object_t = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else {
                service = IOIteratorNext(iterator)
                continue
            }

            if let perfStats = dict["PerformanceStatistics"] as? [String: Any] {
                if let usage = perfStats["Device Utilization %"] as? Int {
                    bestUsage = max(bestUsage, Double(usage))
                } else if let usage = perfStats["GPU Activity(%)"] as? Int {
                    bestUsage = max(bestUsage, Double(usage))
                }
            }

            if let name = dict["IOClass"] as? String, name.contains("Metal") {
                chipName = name
            }
            if let model = dict["model"] as? String {
                chipName = model
            }

            service = IOIteratorNext(iterator)
        }

        let coreCount: Int = {
            var val: Int32 = 0
            var size = MemoryLayout<Int32>.size
            sysctlbyname("hw.perflevel0.logicalcpu", &val, &size, nil, 0)
            return val > 0 ? Int(val) : 0
        }()

        return GPUData(usagePercent: bestUsage, coreCount: coreCount, chipName: chipName)
    }
}
