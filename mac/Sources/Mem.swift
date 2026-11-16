// Rumi — a measuring tool, not a feature: how much memory a running Rumi holds and how much processor time it uses.
// Rumi is more than one process: the app itself (the map of your disk, the scanner) and the web helpers that draw its
// window and the search panel. This adds them up the way Activity Monitor does ("memory footprint").
//   Rumi --mem <pid of a running Rumi> [seconds to watch]
import Foundation
import Darwin

enum Mem {
    struct Proc { let pid: pid_t; let name: String; let footprint: Int64; let cpu: Double }   // bytes, seconds of processor time so far

    private static func usage(_ pid: pid_t) -> (Int64, Double)? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
        guard r == 0 else { return nil }
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let ns = Double(info.ri_user_time + info.ri_system_time) * Double(tb.numer) / Double(tb.denom)
        return (Int64(info.ri_phys_footprint), ns / 1e9)
    }

    private static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        proc_name(pid, &buf, UInt32(buf.count))
        return String(cString: buf)
    }

    /// Which app a helper process is working for (what Activity Monitor groups by).
    private static let responsible: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    /// The app and the web helpers working for it.
    static func family(_ app: pid_t) -> [Proc] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count)))
        var out: [Proc] = []
        for pid in pids.prefix(max(0, n)) where pid > 0 {
            let nm = name(pid)
            guard pid == app || (nm.hasPrefix("com.apple.WebKit") && responsible?(pid) == app), let (fp, cpu) = usage(pid) else { continue }
            out.append(Proc(pid: pid, name: pid == app ? "Rumi (the app, with the map of your disk)" : nm.replacingOccurrences(of: "com.apple.WebKit.", with: "web helper: "), footprint: fp, cpu: cpu))
        }
        return out.sorted { $0.footprint > $1.footprint }
    }

    static func snapshot(_ app: pid_t) -> [String: Any] {
        let f = family(app)
        return ["totalMB": Double(f.reduce(0) { $0 + $1.footprint }) / 1e6, "cpu": f.reduce(0) { $0 + $1.cpu },
                "parts": f.map { ["name": $0.name, "mb": (Double($0.footprint) / 1e5).rounded() / 10] as [String: Any] }]
    }

    static func report(_ app: pid_t, watch: Double) {
        let before = family(app)
        guard !before.isEmpty else { print("no Rumi with that pid"); return }
        for p in before { print(String(format: "%7.1f MB  %@", Double(p.footprint) / 1e6, p.name)) }
        print(String(format: "%7.1f MB  total", Double(before.reduce(0) { $0 + $1.footprint }) / 1e6))
        guard watch > 0 else { return }
        Thread.sleep(forTimeInterval: watch)
        let after = family(app)
        let used = after.reduce(0) { $0 + $1.cpu } - before.reduce(0) { $0 + $1.cpu }
        print(String(format: "over %.0f s: %.2f s of processor time (%.1f%% of one core) · total now %.1f MB", watch, used, used / watch * 100, Double(after.reduce(0) { $0 + $1.footprint }) / 1e6))
    }
}
