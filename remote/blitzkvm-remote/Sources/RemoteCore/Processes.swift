import Darwin
import Foundation

/// One process as the kernel describes it (sysctl KERN_PROC).
public struct ProcInfo: Equatable {
    public var pid: Int32
    public var ppid: Int32
    /// The real uid: for a setuid sudo, the user who ran it.
    public var uid: uid_t
    public var comm: String
    /// Start time (seconds since 1970, with microseconds): with the pid, it
    /// names a process across pid reuse.
    public var start: Double
    public var tty: String?

    public init(pid: Int32, ppid: Int32, uid: uid_t, comm: String, start: Double, tty: String? = nil) {
        self.pid = pid; self.ppid = ppid; self.uid = uid; self.comm = comm; self.start = start; self.tty = tty
    }
}

/// Reads processes without any permission beyond the caller's own: root
/// sees every process's arguments, a user only their own.
public enum Processes {
    public static func info(_ pid: Int32) -> ProcInfo? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0, kp.kp_proc.p_pid == pid else { return nil }
        return proc(kp)
    }

    public static func all() -> [ProcInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        size += size / 8 // room for processes started meanwhile
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &list, &size, nil, 0) == 0 else { return [] }
        return list.prefix(size / MemoryLayout<kinfo_proc>.stride).map(proc)
    }

    private static func proc(_ kp: kinfo_proc) -> ProcInfo {
        var comm = kp.kp_proc.p_comm
        let name = withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let tv = kp.kp_proc.p_un.__p_starttime
        let tdev = kp.kp_eproc.e_tdev
        var tty: String?
        if tdev != -1, tdev != 0, let n = devname(tdev, S_IFCHR) { tty = String(cString: n) }
        return ProcInfo(pid: kp.kp_proc.p_pid, ppid: kp.kp_eproc.e_ppid, uid: kp.kp_eproc.e_pcred.p_ruid,
                        comm: name, start: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6, tty: tty)
    }

    public static func path(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// The current directory, which tells an approver where a command runs.
    public static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// argv from KERN_PROCARGS2: argc, the executable path, padding, then
    /// the arguments (the environment follows and is never read).
    public static func args(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buf.count
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parseProcArgs(Array(buf.prefix(size)))
    }

    static func parseProcArgs(_ buf: [UInt8]) -> [String]? {
        guard buf.count >= 4 else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < buf.count, buf[i] != 0 { i += 1 } // exec path
        while i < buf.count, buf[i] == 0 { i += 1 } // padding
        var out: [String] = []
        while out.count < Int(argc), i < buf.count {
            let start = i
            while i < buf.count, buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    /// A user name for a uid.
    public static func userName(_ uid: uid_t) -> String {
        guard let pw = getpwuid(uid) else { return String(uid) }
        return String(cString: pw.pointee.pw_name)
    }
}
