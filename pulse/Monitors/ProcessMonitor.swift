import Foundation

struct ProcessInfo2: Identifiable {
    let id: Int32
    var name: String
    var cpuPercent: Double
    var memoryMB: Double
    var ports: [UInt16]
    var workingDir: String
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
                ports: [],
                workingDir: workingDir
            ))
        }

        previousSampleTime = now
        let sorted = result.sorted { $0.cpuPercent > $1.cpuPercent }
        return sorted.enumerated().map { idx, proc in
            guard idx < 50 else { return proc }
            return ProcessInfo2(
                id: proc.id,
                name: proc.name,
                cpuPercent: proc.cpuPercent,
                memoryMB: proc.memoryMB,
                ports: listeningPorts(for: proc.id),
                workingDir: proc.workingDir
            )
        }
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
            let localPort = UInt16(bigEndian: UInt16(sinfo.insi_lport & 0xFFFF))
            if localPort > 0 && sockInfo.psi.soi_state & 0x0002 != 0 {
                ports.append(localPort)
            }
        }
        return ports
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
