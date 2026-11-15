// Rumi — "macOS keeps this": what fills the disk outside the folders Rumi maps (~ and /Applications).
// Measured from APFS volume usage (diskutil) plus a size walk of the system folders apps may read.
import Foundation

enum Hidden {
    private static let lock = NSLock()
    private static var cached: [String: Any]?
    private static var measuredAt = Date.distantPast
    private static var running = false
    private static let data = FileManager.default.fileExists(atPath: "/System/Volumes/Data/private") ? "/System/Volumes/Data" : ""

    /// The last measurement, starting a new one in the background when there's none or it's over 10 minutes old.
    static func json() -> [String: Any] {
        lock.lock(); let c = cached, stale = Date().timeIntervalSince(measuredAt) > 600, busy = running; lock.unlock()
        if c == nil || stale, !busy { measure() }
        return c ?? ["status": "measuring"]
    }

    /// Start a measurement on a background queue (no-op while one is running).
    static func measure() {
        lock.lock(); if running { lock.unlock(); return }; running = true; lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let t0 = Date()
            let r = compute()
            lock.lock(); cached = r; measuredAt = Date(); running = false; lock.unlock()
            NSLog("Rumi: measured hidden space in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        }
    }

    // MARK: pieces

    private static func run(_ tool: String, _ args: [String]) -> Data? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return p.terminationStatus == 0 ? d : nil
    }
    private static func plist(_ tool: String, _ args: [String]) -> [String: Any]? {
        guard let d = run(tool, args) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any]
    }

    /// Size on disk of everything under `path`, staying on its volume, counting hard links once. Unreadable folders are skipped.
    private static func size(_ path: String, skip: Set<String> = []) -> Int64 {
        var total: Int64 = 0
        var links = Set<UInt64>()
        guard let cpath = strdup(path) else { return 0 }
        defer { free(cpath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let f = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return 0 }
        defer { fts_close(f) }
        while let e = fts_read(f) {
            let info = Int32(e.pointee.fts_info)
            if info == FTS_D, !skip.isEmpty, skip.contains(String(cString: e.pointee.fts_path)) { fts_set(f, e, FTS_SKIP); continue }
            guard info == FTS_F || info == FTS_SL || info == FTS_SLNONE || info == FTS_D, let st = e.pointee.fts_statp?.pointee else { continue }
            if info == FTS_F, st.st_nlink > 1, !links.insert(UInt64(st.st_ino)).inserted { continue }
            total += Int64(st.st_blocks) * 512
        }
        return total
    }

    private static func allocated(_ p: String) -> Int64 {
        var st = stat(); return lstat(p, &st) == 0 ? Int64(st.st_blocks) * 512 : 0
    }

    private static func compute() -> [String: Any] {
        // APFS volumes in the startup disk's container: the system, its startup/recovery helpers, swap and your data
        var macos: Int64 = 0, vm: Int64 = 0, dataDev = ""
        if let info = plist("/usr/sbin/diskutil", ["info", "-plist", "/"]), let cont = info["APFSContainerReference"] as? String,
           let list = plist("/usr/sbin/diskutil", ["apfs", "list", "-plist", cont]),
           let c = (list["Containers"] as? [[String: Any]])?.first {
            for v in c["Volumes"] as? [[String: Any]] ?? [] {
                let roles = v["Roles"] as? [String] ?? [], used = (v["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
                if roles.contains("Data") { dataDev = v["DeviceIdentifier"] as? String ?? "" }
                else if roles.contains("VM") { vm += used }
                else if !roles.isEmpty, roles.allSatisfy({ ["System", "Preboot", "Recovery", "Update"].contains($0) }) { macos += used }
            }
        }
        // snapshots of your data (Time Machine's and any other app's); APFS doesn't say how big they are
        var snaps: [String] = []
        if !dataDev.isEmpty, let s = plist("/usr/sbin/diskutil", ["apfs", "listSnapshots", "-plist", dataDev]) {
            snaps = (s["Snapshots"] as? [[String: Any]] ?? []).compactMap { $0["SnapshotName"] as? String }
        }
        let sleep = allocated(data + "/private/var/vm/sleepimage")
        // the folder walks run side by side; the biggest (/private) sets the pace
        let homeName = (HOME as NSString).lastPathComponent
        let users = ((try? FileManager.default.contentsOfDirectory(atPath: data + "/Users")) ?? []).filter { $0 != homeName && !$0.hasPrefix(".") }
        typealias Job = (kind: String, path: String, skip: Set<String>)
        var jobs: [Job] = []
        jobs.append(("system", data + "/private/var", [data + "/private/var/vm", data + "/private/var/folders"]))
        for p in ["/private/var/folders", "/private/tmp", "/cores"] { jobs.append(("system", data + p, [])) }
        jobs.append(("library", data + "/Library", []))
        for p in ["/opt", "/usr/local"] { jobs.append(("tools", data + p, [])) }
        for a in ["AssetsV2", "Assets", "PreinstalledAssetsV2", "PreinstalledAssets", "Speech", "Caches"] { jobs.append(("assets", data + "/System/Library/" + a, [])) }
        for u in users { jobs.append(("users", data + "/Users/" + u, [])) }
        var sizes = [Int64](repeating: 0, count: jobs.count)
        let sl = NSLock()
        // two walks at a time: this runs behind the app, so it shouldn't take every core
        var nextJob = 0
        DispatchQueue.concurrentPerform(iterations: min(2, jobs.count)) { _ in
            while true {
                sl.lock(); let i = nextJob; nextJob += 1; sl.unlock()
                if i >= jobs.count { break }
                let n = size(jobs[i].path, skip: jobs[i].skip); sl.lock(); sizes[i] = n; sl.unlock()
            }
        }
        func sum(_ k: String) -> Int64 { var t: Int64 = 0; for (i, j) in jobs.enumerated() where j.kind == k { t += sizes[i] }; return t }
        let assets = sum("assets"), library = sum("library"), system = sum("system"), tools = sum("tools"), others = sum("users")
        let swapLarge = vm + sleep > 12_000_000_000

        func row(_ id: String, _ title: String, _ note: String, _ size: Int64, path: String? = nil, warn: String? = nil) -> [String: Any] {
            var r: [String: Any] = ["id": id, "title": title, "note": note, "size": size]
            if let path { r["path"] = path }
            if let warn { r["warn"] = warn }
            return r
        }
        var rows = [
            row("macos", "macOS itself", "The read-only system and recovery. Updates replace it.", macos),
            row("assets", "Apple Intelligence & downloads", "Models and voices macOS manages by itself", assets, path: "/System/Library/AssetsV2"),
            row("swap", "Memory overflow & sleep image", "Memory parked on disk. A restart resets it.", vm + sleep,
                warn: swapLarge ? "Bigger than usual · a restart frees most" : nil),
            row("system", "System caches & logs", "Managed by macOS. Some clear on restart.", system, path: "/private/var/folders"),
            row("library", "Shared app files", "Fonts, plug-ins and support files in /Library", library, path: "/Library"),
        ]
        if tools > 100_000_000 { rows.append(row("tools", "Homebrew & tools", "In /opt and /usr/local. brew cleanup trims old versions.", tools, path: FileManager.default.fileExists(atPath: "/opt/homebrew") ? "/opt/homebrew" : "/usr/local")) }
        if others > 100_000_000 { rows.append(row("users", "Other users", "Other accounts' home folders", others, path: "/Users")) }
        rows.sort { ($0["size"] as? Int64 ?? 0) > ($1["size"] as? Int64 ?? 0) }
        return ["status": "ready", "measuredAt": Date().timeIntervalSince1970, "rows": rows, "snapshots": snaps.count,
                "newestSnapshot": snaps.sorted().last ?? ""]
    }
}
