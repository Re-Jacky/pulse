# Mac Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menu bar app that shows CPU, Memory, and GPU usage with a beautiful glassy popover and a process manager with kill support.

**Architecture:** Pure AppKit/SwiftUI hybrid — `NSStatusItem` hosts an `NSPopover` containing a SwiftUI root view. A shared `SystemMonitor` `ObservableObject` drives a 2-second `Timer` that refreshes four sub-monitors reading directly from macOS APIs (Mach kernel, IOKit, BSD proc).

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, IOKit, Mach kernel APIs, BSD proc APIs. No external dependencies. Xcode project targeting macOS 13+.

---

## Prerequisites

- Xcode installed and active: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
- Verify: `xcodebuild -version` should print `Xcode 15+`

---

## Task 1: Create the Xcode Project

**Files:**
- Create: `pulse.xcodeproj` (via Xcode UI)
- Create: `pulse/App/AppDelegate.swift`
- Delete: generated `ContentView.swift`, `mac_monitorApp.swift` (SwiftUI lifecycle — we use AppKit)

- [ ] **Step 1: Create project**

Open Xcode → New Project → macOS → App.
- Product Name: `pulse`
- Interface: **SwiftUI** (we still want SwiftUI views — just not the lifecycle)
- Language: Swift
- Uncheck "Include Tests" for now
- Save to `/Users/zyao/Desktop/pulse/`

- [ ] **Step 2: Switch to AppKit lifecycle**

In `pulse/` target, delete `mac_monitorApp.swift` and `ContentView.swift`.

Create `pulse/App/AppDelegate.swift`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let monitor = SystemMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 240)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PopoverView().environmentObject(monitor)
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "System Monitor")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
```

- [ ] **Step 3: Set AppDelegate as entry point**

In `Info.plist`, set:
- `NSPrincipalClass` → `NSApplication`
- `NSMainNibFile` → (remove if present)

Add a `main.swift` file in `App/`:

```swift
import AppKit

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
```

- [ ] **Step 4: Build to confirm it compiles**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build
```

Expected: `BUILD SUCCEEDED` (will have errors about missing types — that's fine, we'll add them next)

- [ ] **Step 5: Commit**

```bash
git init
git add .
git commit -m "feat: create Xcode project with AppKit lifecycle"
```

---

## Task 2: SystemMonitor + CPUMonitor

**Files:**
- Create: `pulse/Monitors/SystemMonitor.swift`
- Create: `pulse/Monitors/CPUMonitor.swift`

- [ ] **Step 1: Create CPUMonitor**

Create `pulse/Monitors/CPUMonitor.swift`:

```swift
import Foundation

final class CPUMonitor {
    private var previousInfo: [processor_info_array_t?] = []
    private var previousCount: mach_msg_type_number_t = 0

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
```

- [ ] **Step 2: Create SystemMonitor**

Create `pulse/Monitors/SystemMonitor.swift`:

```swift
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
```

Note: `ProcessInfo2` is used to avoid collision with Foundation's `ProcessInfo`. Define it in Task 5.

- [ ] **Step 3: Build**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep -E "error:|warning:|BUILD"
```

Expected: errors only about missing `MemoryMonitor`, `GPUMonitor`, `ProcessMonitor`, `ProcessInfo2` — not about `CPUMonitor` or `SystemMonitor`.

- [ ] **Step 4: Commit**

```bash
git add pulse/Monitors/
git commit -m "feat: add CPUMonitor and SystemMonitor scaffold"
```

---

## Task 3: MemoryMonitor

**Files:**
- Create: `pulse/Monitors/MemoryMonitor.swift`

- [ ] **Step 1: Create MemoryMonitor**

Create `pulse/Monitors/MemoryMonitor.swift`:

```swift
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
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

Expected: errors only about missing `GPUMonitor`, `ProcessMonitor`, `ProcessInfo2`.

- [ ] **Step 3: Commit**

```bash
git add pulse/Monitors/MemoryMonitor.swift
git commit -m "feat: add MemoryMonitor using host_statistics64"
```

---

## Task 4: GPUMonitor

**Files:**
- Create: `pulse/Monitors/GPUMonitor.swift`

- [ ] **Step 1: Create GPUMonitor**

Create `pulse/Monitors/GPUMonitor.swift`:

```swift
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
```

- [ ] **Step 2: Add IOKit framework to target**

In Xcode: Target → `pulse` → General → Frameworks and Libraries → `+` → `IOKit.framework`

- [ ] **Step 3: Build**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

Expected: errors only about missing `ProcessMonitor`, `ProcessInfo2`.

- [ ] **Step 4: Commit**

```bash
git add pulse/Monitors/GPUMonitor.swift
git commit -m "feat: add GPUMonitor using IOKit IOAccelerator"
```

---

## Task 5: ProcessMonitor

**Files:**
- Create: `pulse/Monitors/ProcessMonitor.swift`

- [ ] **Step 1: Create ProcessMonitor**

Create `pulse/Monitors/ProcessMonitor.swift`:

```swift
import Foundation

struct ProcessInfo2: Identifiable {
    let id: Int32
    var name: String
    var cpuPercent: Double
    var memoryMB: Double
    var ports: [UInt16]
}

final class ProcessMonitor {
    private var previousCPUTimes: [Int32: UInt64] = [:]
    private var previousSampleTime: UInt64 = 0

    func read() -> [ProcessInfo2] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }

        var pids = [Int32](repeating: 0, count: Int(count) + 16)
        let actual = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        guard actual > 0 else { return [] }

        let now = mach_absolute_time()
        var result: [ProcessInfo2] = []

        for i in 0..<Int(actual) {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }

            var pathBuf = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
            proc_pidpath(pid, &pathBuf, UInt32(PROC_PIDPATHINFO_MAXSIZE))
            let fullPath = String(cString: pathBuf)
            let name = (fullPath as NSString).lastPathComponent.isEmpty
                ? "[\(pid)]"
                : (fullPath as NSString).lastPathComponent

            let cpuTime = info.pti_total_user + info.pti_total_system
            let elapsed = now > previousSampleTime ? now - previousSampleTime : 1
            let cpuDelta = previousCPUTimes[pid].map { cpuTime > $0 ? cpuTime - $0 : 0 } ?? 0
            previousCPUTimes[pid] = cpuTime

            var timeInfo = mach_timebase_info_data_t()
            mach_timebase_info(&timeInfo)
            let elapsedNS = elapsed * UInt64(timeInfo.numer) / UInt64(timeInfo.denom)
            let cpuPercent = elapsedNS > 0 ? min(100.0, Double(cpuDelta) / Double(elapsedNS) * 100.0) : 0.0

            let memMB = Double(info.pti_resident_size) / 1_048_576.0

            result.append(ProcessInfo2(
                id: pid,
                name: name,
                cpuPercent: cpuPercent,
                memoryMB: memMB,
                ports: []
            ))
        }

        previousSampleTime = now
        return result.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    func listeningPorts(for pid: Int32) -> [UInt16] {
        var fdInfo = [proc_fdinfo](repeating: proc_fdinfo(), count: 1024)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fdInfo, Int32(fdInfo.count * MemoryLayout<proc_fdinfo>.size))
        guard bytes > 0 else { return [] }

        let fdCount = Int(bytes) / MemoryLayout<proc_fdinfo>.size
        var ports: [UInt16] = []

        for i in 0..<fdCount {
            guard fdInfo[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            var sockInfo = socket_fdinfo()
            let sz = proc_pidfdinfo(pid, fdInfo[i].proc_fd, PROC_PIDFDSOCKETINFO, &sockInfo, Int32(MemoryLayout<socket_fdinfo>.size))
            guard sz == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
            let sinfo = sockInfo.psi.soi_proto.pri_tcp.tcpsi_ini
            let localPort = UInt16(bigEndian: sinfo.insi_lport)
            if localPort > 0 && sockInfo.psi.soi_state & 0x0002 != 0 {
                ports.append(localPort)
            }
        }
        return ports
    }

    func kill(pid: Int32) -> Result<Void, String> {
        if Darwin.kill(pid, SIGTERM) == 0 { return .success(()) }
        if errno == ESRCH { return .failure("Process no longer exists") }
        if errno == EPERM { return .failure("Permission denied") }
        return .failure("Failed to kill process (errno \(errno))")
    }
}
```

- [ ] **Step 2: Build — expect clean compile**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED` (or only linker warnings about missing views).

- [ ] **Step 3: Commit**

```bash
git add pulse/Monitors/ProcessMonitor.swift
git commit -m "feat: add ProcessMonitor with CPU%, memory, port detection, and kill"
```

---

## Task 6: Color helpers + MetricRowView

**Files:**
- Create: `pulse/Views/Colors.swift`
- Create: `pulse/Views/MetricRowView.swift`

- [ ] **Step 1: Create Colors.swift**

Create `pulse/Views/Colors.swift`:

```swift
import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
```

- [ ] **Step 2: Create MetricRowView**

Create `pulse/Views/MetricRowView.swift`:

```swift
import SwiftUI

struct MetricRowView: View {
    let label: String
    let value: String
    let subtext: String
    let percent: Double
    let fillColors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 10, weight: .regular))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 36, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 4)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                LinearGradient(
                                    colors: fillColors,
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * CGFloat(min(1.0, max(0.0, percent / 100.0))), height: 4)
                            .animation(.easeInOut(duration: 0.4), value: percent)
                    }
                }
                .frame(height: 4)

                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(fillColors.first ?? .white)
                    .frame(width: 56, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Text(subtext)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.28))
                .padding(.leading, 44)
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 3: Commit**

```bash
git add pulse/Views/Colors.swift pulse/Views/MetricRowView.swift
git commit -m "feat: add Color(hex:) helper and MetricRowView with animated gradient bar"
```

---

## Task 7: OverviewView

**Files:**
- Create: `pulse/Views/OverviewView.swift`

- [ ] **Step 1: Create OverviewView**

Create `pulse/Views/OverviewView.swift`:

```swift
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MetricRowView(
                label: "CPU",
                value: String(format: "%.0f%%", monitor.cpuUsage),
                subtext: "\(monitor.cpuCoreCount)-core · \(monitor.cpuChipName)",
                percent: monitor.cpuUsage,
                fillColors: [Color(hex: "#60d394"), Color(hex: "#4ade80")]
            )

            MetricRowView(
                label: "MEM",
                value: String(format: "%.1f / %.0f GB", monitor.memUsedGB, monitor.memTotalGB),
                subtext: String(format: "%.1f GB used", monitor.memUsedGB),
                percent: monitor.memTotalGB > 0 ? (monitor.memUsedGB / monitor.memTotalGB) * 100 : 0,
                fillColors: [Color(hex: "#60a5fa"), Color(hex: "#818cf8")]
            )

            MetricRowView(
                label: "GPU",
                value: monitor.gpuUsage >= 0 ? String(format: "%.0f%%", monitor.gpuUsage) : "N/A",
                subtext: monitor.gpuCoreCount > 0 ? "\(monitor.gpuCoreCount)-core · \(monitor.gpuChipName)" : monitor.gpuChipName,
                percent: monitor.gpuUsage,
                fillColors: [Color(hex: "#f472b6"), Color(hex: "#e879f9")]
            )
        }
        .padding(16)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 3: Commit**

```bash
git add pulse/Views/OverviewView.swift
git commit -m "feat: add OverviewView with CPU/Memory/GPU metric rows"
```

---

## Task 8: ProcessListView + ProcessRowView

**Files:**
- Create: `pulse/Views/ProcessRowView.swift`
- Create: `pulse/Views/ProcessListView.swift`

- [ ] **Step 1: Create ProcessRowView**

Create `pulse/Views/ProcessRowView.swift`:

```swift
import SwiftUI

struct ProcessRowView: View {
    let process: ProcessInfo2
    let onKill: () -> Void

    private var cpuColor: Color {
        switch process.cpuPercent {
        case ..<5: return .white.opacity(0.6)
        case 5..<70: return Color(hex: "#60d394")
        case 70..<90: return Color(hex: "#f59e0b")
        default: return Color(hex: "#ef4444")
        }
    }

    private var memText: String {
        let mb = process.memoryMB
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    private var pidText: String {
        let portStr = process.ports.isEmpty ? "" : " · :\(process.ports.first!)"
        return "PID \(process.id)\(portStr)"
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(pidText)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.30))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.1f%%", process.cpuPercent))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(cpuColor)
                Text(memText)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.38))
            }
            .frame(width: 60, alignment: .trailing)
        }
        .frame(height: 36)
        .padding(.horizontal, 4)
        .background(Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive, action: onKill) {
                Label("Kill Process", systemImage: "xmark.circle")
            }
        }
    }
}
```

- [ ] **Step 2: Create ProcessListView**

Create `pulse/Views/ProcessListView.swift`:

```swift
import SwiftUI

struct ProcessListView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @State private var searchText = ""
    @State private var sortByColumn: SortColumn = .cpu
    @State private var sortAscending = false
    @State private var processToKill: ProcessInfo2? = nil
    @State private var killError: String? = nil
    @State private var showKillConfirm = false

    private let processMonitor = ProcessMonitor()

    enum SortColumn { case name, cpu, mem }

    private var filtered: [ProcessInfo2] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        let base: [ProcessInfo2]
        if trimmed.isEmpty {
            base = monitor.processes
        } else if let port = UInt16(trimmed) {
            base = monitor.processes.filter { $0.ports.contains(port) }
        } else {
            base = monitor.processes.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
            }
        }

        return base.sorted {
            switch sortByColumn {
            case .name: return sortAscending ? $0.name < $1.name : $0.name > $1.name
            case .cpu: return sortAscending ? $0.cpuPercent < $1.cpuPercent : $0.cpuPercent > $1.cpuPercent
            case .mem: return sortAscending ? $0.memoryMB < $1.memoryMB : $0.memoryMB > $1.memoryMB
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter by name or port…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1))
                .cornerRadius(7)
                .padding(.bottom, 10)

            HStack(spacing: 0) {
                sortHeader("NAME", column: .name, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                sortHeader("CPU", column: .cpu, alignment: .trailing)
                    .frame(width: 38, alignment: .trailing)
                sortHeader("MEM", column: .mem, alignment: .trailing)
                    .frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)

            Divider().background(Color.white.opacity(0.06))

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { process in
                        ProcessRowView(process: process) {
                            processToKill = process
                            showKillConfirm = true
                        }
                        Divider().background(Color.white.opacity(0.04))
                    }
                }
            }

            Text("Right-click a process to kill it")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.20))
                .padding(.top, 8)
        }
        .padding(16)
        .alert("Kill Process?", isPresented: $showKillConfirm, presenting: processToKill) { p in
            Button("Cancel", role: .cancel) {}
            Button("Kill \(p.name)", role: .destructive) {
                let result = processMonitor.kill(pid: p.id)
                if case .failure(let msg) = result {
                    killError = msg
                }
            }
        } message: { p in
            Text("Kill \(p.name) (PID \(p.id))?")
        }
        .alert("Error", isPresented: .init(get: { killError != nil }, set: { if !$0 { killError = nil } })) {
            Button("OK") { killError = nil }
        } message: {
            Text(killError ?? "")
        }
    }

    @ViewBuilder
    private func sortHeader(_ title: String, column: SortColumn, alignment: Alignment) -> some View {
        Button(action: {
            if sortByColumn == column {
                sortAscending.toggle()
            } else {
                sortByColumn = column
                sortAscending = column == .name
            }
        }) {
            HStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .regular))
                    .textCase(.uppercase)
                    .tracking(1.0)
                    .foregroundColor(.white.opacity(sortByColumn == column ? 0.6 : 0.25))
                if sortByColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 4: Commit**

```bash
git add pulse/Views/ProcessRowView.swift pulse/Views/ProcessListView.swift
git commit -m "feat: add ProcessListView with search, sort, and kill"
```

---

## Task 9: PopoverView (root + tab switcher)

**Files:**
- Create: `pulse/Views/PopoverView.swift`

- [ ] **Step 1: Create PopoverView**

Create `pulse/Views/PopoverView.swift`:

```swift
import SwiftUI

struct PopoverView: View {
    @State private var selectedTab = 0

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("Overview").tag(0)
                    Text("Processes").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)

                if selectedTab == 0 {
                    OverviewView()
                } else {
                    ProcessListView()
                }
            }
        }
        .frame(width: 300)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
```

- [ ] **Step 2: Build — expect BUILD SUCCEEDED**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add pulse/Views/PopoverView.swift
git commit -m "feat: add PopoverView with tab switcher and visual effect background"
```

---

## Task 10: Wire up AppDelegate + first run

**Files:**
- Modify: `pulse/App/AppDelegate.swift`

- [ ] **Step 1: Update popover size to auto-size by tab**

Update `AppDelegate.swift` to resize the popover when tab changes. The `PopoverView` already handles this via content size — just ensure the popover's `contentSize` is not hard-coded. Remove the fixed `contentSize` set in `applicationDidFinishLaunching` (the SwiftUI view will size it):

```swift
// Remove this line from applicationDidFinishLaunching:
// popover.contentSize = NSSize(width: 300, height: 240)
```

- [ ] **Step 2: Build and run**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

Then run the app from Xcode (⌘R) or:

```bash
open ~/Library/Developer/Xcode/DerivedData/pulse-*/Build/Products/Debug/pulse.app
```

Expected: CPU chip icon appears in menu bar. Click it → popover opens with Overview and Processes tabs.

- [ ] **Step 3: Verify each feature manually**

- [ ] CPU row shows a percentage and updates every 2 seconds
- [ ] Memory row shows `X.X / Y GB`
- [ ] GPU row shows percentage (or `N/A` in a VM)
- [ ] Processes tab shows a scrollable list sorted by CPU%
- [ ] Search field filters by name
- [ ] Search field filters by port number (try `3000` if a Node server is running)
- [ ] Right-click a process → Kill → confirmation appears → Cancel works
- [ ] Clicking outside popover dismisses it

- [ ] **Step 4: Final commit**

```bash
git add .
git commit -m "feat: wire up AppDelegate, app fully functional"
```

---

## Task 11: Port detection integration

The `ProcessMonitor.listeningPorts()` method exists but isn't called during `read()` (it's expensive per-process). Wire it up for a lightweight port scan on each refresh.

**Files:**
- Modify: `pulse/Monitors/ProcessMonitor.swift`

- [ ] **Step 1: Call listeningPorts during read for top processes only**

Update the `read()` method in `ProcessMonitor.swift`. After sorting, enrich the top 50 processes with port info:

```swift
// At the end of read(), before returning, replace:
// return result.sorted { $0.cpuPercent > $1.cpuPercent }

let sorted = result.sorted { $0.cpuPercent > $1.cpuPercent }
return sorted.enumerated().map { idx, proc in
    if idx < 50 {
        var enriched = proc
        enriched = ProcessInfo2(
            id: proc.id,
            name: proc.name,
            cpuPercent: proc.cpuPercent,
            memoryMB: proc.memoryMB,
            ports: listeningPorts(for: proc.id)
        )
        return enriched
    }
    return proc
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

Run the app. If you have a local server running on a known port (e.g. `:3000`), it should appear in the process list alongside the PID.

- [ ] **Step 3: Commit**

```bash
git add pulse/Monitors/ProcessMonitor.swift
git commit -m "feat: enrich top 50 processes with listening port info"
```
