import Foundation

struct ProcessInfo2: Identifiable {
    let id: Int32
    var name: String
    var cpuPercent: Double
    var memoryMB: Double
    var ports: [UInt16]
    var workingDir: String
    /// Full command line (argv joined), nil when unreadable (e.g. other users' processes).
    var commandLine: String?
    /// Parent PID, 0 when unknown.
    var parentPid: Int32
    /// Process start time, nil when unknown.
    var startTime: Date?
}

final class ProcessMonitor {
    /// How often listening-port / command-line metadata is rescanned. Ports and
    /// argv change rarely, so this runs far less often than the 2s CPU loop and
    /// off the main thread; `read()` serves the cached values.
    static let serverMetadataRefreshInterval: TimeInterval = 8

    private var previousCPUTimes: [Int32: UInt64] = [:]
    private var previousSampleTime: UInt64 = 0

    private let metadataLock = NSLock()
    private var cachedPorts: [Int32: [UInt16]] = [:]
    private var cachedCommandLine: [Int32: String] = [:]
    private var cachedParentPid: [Int32: Int32] = [:]
    private var cachedStartTime: [Int32: Date] = [:]
    private var lastMetadataRefresh = Date.distantPast
    private var metadataRefreshInFlight = false
    private let metadataQueue = DispatchQueue(label: "pulse.processServerMetadata", qos: .utility)

    func read() -> [ProcessInfo2] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }

        var pids = [Int32](repeating: 0, count: Int(count) + 16)
        let actual = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        guard actual > 0 else { return [] }

        let now = mach_absolute_time()
        var result: [ProcessInfo2] = []

        metadataLock.lock()
        let portsSnapshot = cachedPorts
        let commandLineSnapshot = cachedCommandLine
        let parentPidSnapshot = cachedParentPid
        let startTimeSnapshot = cachedStartTime
        metadataLock.unlock()

        for i in 0..<Int(actual) {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }

            var pathBuf = [CChar](repeating: 0, count: 4096)
            proc_pidpath(pid, &pathBuf, 4096)
            let fullPath = String(cString: pathBuf)
            let name = (fullPath as NSString).lastPathComponent.isEmpty
                ? "[\(pid)]"
                : (fullPath as NSString).lastPathComponent

            var vnodeInfo = proc_vnodepathinfo()
            let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            let workingDir: String
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, vnodeSize) == vnodeSize {
                workingDir = withUnsafeBytes(of: &vnodeInfo.pvi_cdir.vip_path) { rawBuf in
                    let ptr = rawBuf.bindMemory(to: CChar.self).baseAddress!
                    return String(cString: ptr)
                }
            } else {
                workingDir = ""
            }

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
                ports: portsSnapshot[pid] ?? [],
                workingDir: workingDir,
                commandLine: commandLineSnapshot[pid],
                parentPid: parentPidSnapshot[pid] ?? 0,
                startTime: startTimeSnapshot[pid]
            ))
        }

        previousSampleTime = now

        let livePIDs = Set(result.map(\.id))
        for deadPID in Set(previousCPUTimes.keys).subtracting(livePIDs) {
            previousCPUTimes.removeValue(forKey: deadPID)
        }

        refreshServerMetadataIfNeeded()
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
            guard sockInfo.psi.soi_kind == 2 else { continue }
            guard sockInfo.psi.soi_proto.pri_tcp.tcpsi_state == 1 else { continue }
            let localPort = UInt16(bigEndian: UInt16(sockInfo.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport & 0xFFFF))
            if localPort > 0 {
                ports.append(localPort)
            }
        }
        return ports
    }

    /// Rescans listening ports, command lines, and parent/start metadata for all
    /// processes on a background queue, throttled to
    /// `serverMetadataRefreshInterval`. Idle dev servers sit at ~0% CPU, so
    /// port discovery must not be gated on CPU rank.
    private func refreshServerMetadataIfNeeded() {
        metadataLock.lock()
        let due =
            Date().timeIntervalSince(lastMetadataRefresh) >= Self.serverMetadataRefreshInterval
            && !metadataRefreshInFlight
        if due {
            metadataRefreshInFlight = true
        }
        metadataLock.unlock()
        guard due else { return }
        metadataQueue.async { [weak self] in
            self?.refreshServerMetadata()
        }
    }

    private func refreshServerMetadata() {
        let count = proc_listallpids(nil, 0)
        var pids: [Int32] = []
        if count > 0 {
            var buf = [Int32](repeating: 0, count: Int(count) + 16)
            let actual = proc_listallpids(&buf, Int32(buf.count) * Int32(MemoryLayout<Int32>.size))
            if actual > 0 {
                pids = Array(buf.prefix(Int(actual)))
            }
        }

        var ports: [Int32: [UInt16]] = [:]
        var commandLines: [Int32: String] = [:]
        var parentPids: [Int32: Int32] = [:]
        var startTimes: [Int32: Date] = [:]
        for pid in pids where pid > 0 {
            let listening = listeningPorts(for: pid)
            if !listening.isEmpty {
                ports[pid] = listening
            }
            if let commandLine = commandLine(for: pid) {
                commandLines[pid] = commandLine
            }
            if let bsd = bsdInfo(for: pid) {
                parentPids[pid] = bsd.parentPid
                if let startTime = bsd.startTime {
                    startTimes[pid] = startTime
                }
            }
        }

        metadataLock.lock()
        cachedPorts = ports
        cachedCommandLine = commandLines
        cachedParentPid = parentPids
        cachedStartTime = startTimes
        lastMetadataRefresh = Date()
        metadataRefreshInFlight = false
        metadataLock.unlock()
    }

    private func bsdInfo(for pid: Int32) -> (parentPid: Int32, startTime: Date?)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let startTime: Date? =
            info.pbi_start_tvsec > 0
            ? Date(
                timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                    + TimeInterval(info.pbi_start_tvusec) / 1_000_000
            ) : nil
        return (parentPid: Int32(info.pbi_ppid), startTime: startTime)
    }

    /// Full command line for a process via KERN_PROCARGS2. Same-uid only;
    /// returns nil for other users' processes or on failure.
    private func commandLine(for pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        let fetched: Int = buf.withUnsafeMutableBufferPointer { ptr in
            var len = size
            guard let base = ptr.baseAddress else { return 0 }
            guard sysctl(&mib, u_int(mib.count), base, &len, nil, 0) == 0 else { return 0 }
            return len
        }
        guard fetched > 0 else { return nil }
        return buf.withUnsafeBufferPointer { ptr in
            Self.parseProcessArgs(ptr, count: fetched)
        }
    }

    /// Pure parser for the KERN_PROCARGS2 buffer layout: Int32 argc, exec-path
    /// C string, then argc argv C strings. Separated for testability.
    static func parseProcessArgs(_ ptr: UnsafeBufferPointer<CChar>, count: Int) -> String? {
        guard let base = ptr.baseAddress, count > MemoryLayout<Int32>.size else { return nil }
        var argc: Int32 = 0
        memcpy(&argc, base, MemoryLayout<Int32>.size)
        guard argc > 0, argc < 4096 else { return nil }
        var offset = MemoryLayout<Int32>.size
        // Skip the executable path.
        while offset < count && base[offset] != 0 { offset += 1 }
        offset += 1
        var args: [String] = []
        args.reserveCapacity(Int(argc))
        while offset < count && args.count < Int(argc) {
            while offset < count && base[offset] == 0 { offset += 1 }
            guard offset < count else { break }
            let start = offset
            while offset < count && base[offset] != 0 { offset += 1 }
            let length = offset - start
            if length > 0 {
                let bytes = UnsafeRawBufferPointer(start: base + start, count: length)
                if let arg = String(bytes: bytes, encoding: .utf8), !arg.isEmpty {
                    args.append(arg)
                }
            }
            offset += 1
        }
        guard !args.isEmpty else { return nil }
        return String(args.joined(separator: " ").prefix(512))
    }

    enum KillError: Error, CustomStringConvertible {
        case notFound
        case permissionDenied
        case other(Int32)
        var description: String {
            switch self {
            case .notFound: return "Process no longer exists"
            case .permissionDenied: return "Permission denied"
            case .other(let e): return "Failed to kill process (errno \(e))"
            }
        }
    }

    func kill(pid: Int32) -> Result<Void, KillError> {
        if Darwin.kill(pid, SIGTERM) == 0 { return .success(()) }
        if errno == ESRCH { return .failure(.notFound) }
        if errno == EPERM { return .failure(.permissionDenied) }
        return .failure(.other(errno))
    }
}
