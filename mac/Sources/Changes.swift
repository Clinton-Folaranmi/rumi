// Rumi — what changed since last time (v1.2).
// Every scan is compared with an earlier one, the "comparison scan" (baseline.bin, a copy of an older last-scan.bin).
// Each folder and file remembers what it was then (`was`), each folder what has gone from it (`gone`), so the map can
// say what grew, shrank, is new or was removed. The comparison scan stays the same for the rest of the day: it's only
// replaced when the scan being retired is at least 12 hours older than the new one, so "since Thursday" doesn't turn
// into "since a minute ago" after a Rescan.
// A small history of every scan (date, used, free, biggest folders) is kept beside it for the forecast planned later.
import Foundation

enum Changes {
    static let MIN: Int64 = 1 << 20        // changes under 1 MB aren't shown
    static let KEEP: Double = 12 * 3600    // see above
    static let TOP_MIN: Int64 = 10 << 20   // the header line names folders that moved by 10 MB or more

    /// Compare a fresh, not yet shared tree with the comparison scan. Returns when that scan was made (0: there is none)
    /// and how full the disk was then (-1: not known).
    static func compare(_ top: Dir, roots: [String], now: Double) -> (at: Double, used: Int64) {
        Snapshot.writeQ.sync {   // behind any save still on its way
            let fm = FileManager.default, last = Snapshot.treeURL, base = Snapshot.baselineURL
            guard let lastAt = Snapshot.scannedAt(last) else { return }
            if Snapshot.scannedAt(base) == nil || now - lastAt >= KEEP {
                try? fm.removeItem(at: base)
                try? fm.copyItem(at: last, to: base)
            }
        }
        guard let b = Snapshot.load(roots: roots, from: Snapshot.baselineURL) else { return (0, -1) }
        diff(top, b.top)
        addUp(top)
        return (b.scannedAt, History.used(at: b.scannedAt))
    }

    /// The same hand-over when a saved map is brought up to date from the file-system log instead of by a scan: if it's
    /// 12 hours old or more, it becomes the comparison scan, and every mark starts again from "nothing changed". Call
    /// right after the map is read from its file, before any change is folded in.
    static func newDay(_ S: Store, mapAt: Double) {
        guard Date().timeIntervalSince1970 - mapAt >= KEEP else { return }
        let ok: Bool = Snapshot.writeQ.sync {
            let fm = FileManager.default
            guard Snapshot.scannedAt(Snapshot.treeURL).map({ abs($0 - mapAt) < 1 }) == true else { return false }
            try? fm.removeItem(at: Snapshot.baselineURL)
            return (try? fm.copyItem(at: Snapshot.treeURL, to: Snapshot.baselineURL)) != nil
        }
        guard ok else { return }
        let used = History.used(near: mapAt)
        S.lock.lock(); defer { S.lock.unlock() }
        guard let top = S.root, abs(S.finished - mapAt) < 1 else { return }
        var stack = [top]
        while let d = stack.popLast() {
            d.was = d.size; d.wasSmall = d.small; d.gone = []; d.churn = 0
            for i in d.files.indices { d.files[i].was = d.files[i].alloc }
            stack.append(contentsOf: d.dirs)
        }
        S.baselineAt = mapAt; S.baseUsed = used; S.churnStale = false
    }

    /// Mark every folder and file in `top` with what it was in `base`, matched by name level by level.
    static func diff(_ top: Dir, _ base: Dir) {
        var stack: [(Dir, Dir?)] = [(top, base)]
        while let (n, o) = stack.popLast() {
            n.was = o?.size ?? -1
            n.wasSmall = o?.small ?? 0
            n.gone = []
            guard let o = o else {   // a new folder: everything in it is new
                for i in n.files.indices { n.files[i].was = -1 }
                for c in n.dirs { stack.append((c, nil)) }
                continue
            }
            var od: [String: Dir] = [:]
            for c in o.dirs { od[c.name] = c }
            for c in n.dirs { stack.append((c, od.removeValue(forKey: c.name))) }
            for (_, g) in od where g.size >= MIN { n.gone.append(Gone(name: g.name, size: g.size, dir: true, cat: g.cat)) }
            var of: [String: Int] = [:]
            for (i, f) in o.files.enumerated() { of[f.name] = i }
            for i in n.files.indices { n.files[i].was = of.removeValue(forKey: n.files[i].name).map { o.files[$0].alloc } ?? -1 }
            for (_, i) in of { let g = o.files[i]; n.gone.append(Gone(name: g.name, size: g.alloc, dir: false, cat: g.cat)) }
        }
    }

    /// Add up how much moved inside every folder: what grew, shrank, is new or gone, children first.
    static func addUp(_ top: Dir) {
        var order: [Dir] = [], stack = [top]
        order.reserveCapacity(150_000)
        while let d = stack.popLast() { order.append(d); stack.append(contentsOf: d.dirs) }
        for d in order.reversed() {
            if d.was < 0 { d.churn = d.size; continue }
            var c = abs(d.small - d.wasSmall)
            for f in d.files { c += f.was < 0 ? f.alloc : abs(f.alloc - f.was) }
            for g in d.gone { c += g.size }
            for ch in d.dirs { c += ch.churn }
            d.churn = c
        }
    }

    /// Call with `lock` held before reading `churn`: a trash since the last scan means adding up again.
    static func fresh(_ S: Store) {
        guard S.churnStale, let top = S.root else { return }
        addUp(top); S.churnStale = false
    }

    static func delta(_ d: Dir) -> Int64 { d.size - max(d.was, 0) }
    static func delta(_ f: FileRec) -> Int64 { f.alloc - max(f.was, 0) }

    // MARK: the header line

    /// Net change and the three things that moved most. Call with `lock` held. `usedNow`: the disk's used space.
    static func summary(_ S: Store, usedNow: Int64) -> [String: Any]? {
        guard S.baselineAt > 0, let top = S.root else { return nil }
        fresh(S)
        var movers: [(name: String, path: String, d: Int64, type: String)] = []
        for r in top.dirs {
            for c in r.dirs { movers.append(lead(c, r.name + "/" + c.name)) }
            for f in r.files where delta(f) != 0 { movers.append((f.name, r.name + "/" + f.name, delta(f), "file")) }
            for g in r.gone { movers.append((g.name, r.name + "/" + g.name, -g.size, "gone")) }
        }
        movers = movers.filter { abs($0.d) >= TOP_MIN }.sorted { abs($0.d) > abs($1.d) }
        var out: [String: Any] = ["since": S.baselineAt, "net": delta(top), "churn": top.churn,
                                  "top": movers.prefix(3).map { ["name": $0.name, "path": $0.path, "d": $0.d, "type": $0.type] as [String: Any] }]
        if S.baseUsed >= 0 { out["used"] = usedNow - S.baseUsed }
        return out
    }

    /// The most specific thing that explains a folder's change: follow the child that accounts for 70% or more of it,
    /// up to two levels down ("Library +3 GB" becomes "Caches", then "Browser +2.9 GB"; deeper names mean nothing out of
    /// place). Stops at apps and libraries.
    private static func lead(_ d: Dir, _ path: String) -> (name: String, path: String, d: Int64, type: String) {
        var cur = d, p = path
        for _ in 0..<2 {
            let dd = delta(cur)
            guard dd != 0, cur.was >= 0, !cur.pkg else { break }
            func explains(_ x: Int64) -> Bool { (x > 0) == (dd > 0) && abs(x) * 10 >= abs(dd) * 7 }
            if let f = cur.files.first(where: { explains(delta($0)) }) { return (f.name, p + "/" + f.name, delta(f), "file") }
            if let g = cur.gone.first(where: { explains(-$0.size) }) { return (g.name, p + "/" + g.name, -g.size, "gone") }
            guard let c = cur.dirs.first(where: { explains(delta($0)) }) else { break }
            cur = c; p += "/" + c.name
        }
        return (cur.name, p, delta(cur), "dir")
    }

    // MARK: the Changed view

    /// What changed inside a folder, laid out like the map: folders with their changed contents, sized by how much
    /// moved (`w`), each with its net change (`d`). Things that are gone come as type "gone", with no path.
    static func json(path: String) -> (Int, [String: Any]) {
        let S = Store.shared
        let used = diskInfo()["used"] as? Int64 ?? 0
        S.lock.lock(); defer { S.lock.unlock() }
        guard let top = S.root else { return (409, ["error": "not ready"]) }
        guard let n = path.isEmpty ? top : S.index[path] else { return (404, ["error": "not found"]) }
        let np = n.parent != nil ? n.path : ""
        guard S.baselineAt > 0 else {
            return (200, ["since": 0, "net": 0, "churn": 0, "node": ["name": "changes", "path": np, "size": 0, "type": "dir", "cat": "other", "children": [Any](), "hasKids": false]])
        }
        fresh(S)
        let kids = items(n, np, depth: 2)
        var out: [String: Any] = ["since": S.baselineAt, "net": delta(n), "churn": n.churn,
                                  "node": ["name": "changes", "path": np, "size": n.size, "w": n.churn, "d": delta(n), "type": "dir",
                                           "cat": CATS[n.cat], "children": kids, "hasKids": !kids.isEmpty] as [String: Any]]
        if path.isEmpty, S.baseUsed >= 0 { out["sys"] = (used - S.baseUsed) - delta(top) }
        return (200, out)
    }

    private static func items(_ d: Dir, _ path: String, depth: Int) -> [[String: Any]] {
        enum It { case dir(Dir), file(FileRec), gone(Gone), small(Int64) }
        var all: [(Int64, It)] = []
        for c in d.dirs where c.churn >= MIN { all.append((c.churn, .dir(c))) }
        for f in d.files { let w = f.was < 0 ? f.alloc : abs(f.alloc - f.was); if w >= MIN { all.append((w, .file(f))) } }
        for g in d.gone where g.size >= MIN { all.append((g.size, .gone(g))) }
        if d.was >= 0, abs(d.small - d.wasSmall) >= MIN { all.append((abs(d.small - d.wasSmall), .small(d.small - d.wasSmall))) }
        all.sort { $0.0 > $1.0 }
        func net(_ it: It) -> Int64 {
            switch it { case .dir(let c): return delta(c); case .file(let f): return delta(f); case .gone(let g): return -g.size; case .small(let s): return s }
        }
        var kids: [[String: Any]] = []
        for (w, it) in all.prefix(CHILD_LIMIT) {
            switch it {
            case .dir(let c):
                let cp = c.name.hasPrefix("/") ? c.name : path + "/" + c.name
                kids.append(["name": c.name, "path": cp, "size": c.size, "w": w, "d": delta(c), "new": c.was < 0, "count": c.count, "type": "dir",
                             "cat": CATS[c.cat], "mtime": c.mtime, "denied": c.denied, "pkg": c.pkg, "ch": 1,
                             "hasKids": !c.dirs.isEmpty || !c.files.isEmpty,
                             "children": depth > 1 && !c.pkg ? items(c, cp, depth: depth - 1) as Any : NSNull()])
            case .file(let f):
                kids.append(["name": f.name, "path": path + "/" + f.name, "size": f.alloc, "w": w, "d": delta(f), "new": f.was < 0, "type": "file",
                             "cat": CATS[f.cat], "mtime": f.mtime, "ch": 1])
            case .gone(let g):
                kids.append(["name": g.name, "at": path + "/" + g.name, "size": g.size, "w": w, "d": -g.size, "type": "gone", "wasDir": g.dir,
                             "cat": CATS[g.cat], "ch": 1])
            case .small(let s):
                kids.append(["name": "Smaller items", "size": w, "w": w, "d": s, "type": "rest", "cat": "other", "ch": 1])
            }
        }
        let left = all.dropFirst(CHILD_LIMIT)
        if !left.isEmpty {
            let w = left.reduce(Int64(0)) { $0 + $1.0 }
            kids.append(["name": "\(commas(left.count)) more", "size": w, "w": w, "d": left.reduce(Int64(0)) { $0 + net($1.1) }, "type": "rest",
                         "cat": "other", "ch": 1, "n": left.count])
        }
        return kids
    }
}

/// One line per scan: when, how full the disk was, how much the map held, and the biggest folders.
enum History {
    private static let lock = NSLock()

    private static func load() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: Snapshot.historyURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["version"] as? Int == 1 else { return [] }
        return obj["scans"] as? [[String: Any]] ?? []
    }

    /// Call while the tree isn't shared yet (the end of a scan), or with the store's lock held.
    static func record(at t: Double, top: Dir) {
        let disk = diskInfo()
        var folders: [(String, Int64)] = []
        for r in top.dirs { for c in r.dirs { folders.append((r.name + "/" + c.name, c.size)) } }
        folders.sort { $0.1 > $1.1 }
        let entry: [String: Any] = ["t": t, "used": disk["used"] ?? 0, "free": disk["free"] ?? 0, "mapped": top.size, "files": top.count,
                                    "top": folders.prefix(20).map { [$0.0, $0.1] as [Any] }]
        lock.lock(); defer { lock.unlock() }
        var scans = load()
        scans.append(entry)
        write(thin(scans, now: t))
    }

    /// The disk's used space when the scan made at `t` finished (-1: not on record).
    static func used(at t: Double) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        for s in load() where abs((s["t"] as? Double ?? 0) - t) < 2 { return (s["used"] as? NSNumber)?.int64Value ?? -1 }
        return -1
    }

    /// The disk's used space on the record closest to `t`, if one is within three hours (-1: none).
    static func used(near t: Double) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let best = load().min { abs(($0["t"] as? Double ?? 0) - t) < abs(($1["t"] as? Double ?? 0) - t) }
        guard let b = best, abs((b["t"] as? Double ?? 0) - t) < 3 * 3600 else { return -1 }
        return (b["used"] as? NSNumber)?.int64Value ?? -1
    }

    /// A line without a scan: just when, and how full the disk is. Rumi adds one an hour while it runs (the forecast
    /// needs the days Rumi wasn't opened too), and one whenever a saved map is brought up to date.
    static func sample(force: Bool = false) {
        let disk = diskInfo(), t = Date().timeIntervalSince1970
        lock.lock(); defer { lock.unlock() }
        var scans = load()
        if !force, let last = scans.last?["t"] as? Double, t - last < 3300 { return }
        scans.append(["t": t, "used": disk["used"] ?? 0, "free": disk["free"] ?? 0])
        write(thin(scans, now: t))
    }

    /// The last two days keep every line; before that, the last line of each day.
    private static func thin(_ scans: [[String: Any]], now t: Double) -> [[String: Any]] {
        let cal = Calendar.current, recent = t - 48 * 3600
        var seen = Set<DateComponents>(), kept: [[String: Any]] = []
        for s in scans.reversed() {
            let st = s["t"] as? Double ?? 0
            if st >= recent { kept.append(s); continue }
            if seen.insert(cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: st))).inserted { kept.append(s) }
        }
        return Array(kept.reversed().suffix(1500))
    }

    private static func write(_ scans: [[String: Any]]) {
        try? jsonData(["version": 1, "scans": scans]).write(to: Snapshot.historyURL, options: .atomic)
    }

    private static var told: (at: Double, what: [String: Any]?) = (0, nil)
    /// The forecast for the page's header, worked out at most every ten minutes.
    static func forecastNow() -> [String: Any]? {
        let now = Date().timeIntervalSince1970
        lock.lock(); let t = told; lock.unlock()
        if now - t.at < 600 { return t.what }
        let f = forecast(now: now)
        lock.lock(); told = (now, f); lock.unlock()
        return f
    }

    /// "Full in about three weeks": only when free space has fallen steadily and would run out within 60 days.
    /// One point per day over the last 30 days, a straight line through them. Nil when there's too little to go on,
    /// the disk isn't filling, the days disagree too much with the line, or the date is further off.
    static func forecast(now: Double = Date().timeIntervalSince1970, free: Int64? = nil, lines: [[String: Any]]? = nil) -> [String: Any]? {
        var all = lines ?? []
        if lines == nil { lock.lock(); all = load(); lock.unlock() }
        let cal = Calendar.current
        var days: [DateComponents: (t: Double, free: Double)] = [:]
        for s in all {
            guard let t = s["t"] as? Double, t >= now - 30 * 86400, t <= now, let f = (s["free"] as? NSNumber)?.doubleValue else { continue }
            let k = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
            if days[k] == nil || days[k]!.t < t { days[k] = (t, f) }
        }
        let pts = days.values.sorted { $0.t < $1.t }
        guard pts.count >= 6, let a = pts.first, let b = pts.last, b.t - a.t >= 6 * 86400 else { return nil }
        let n = Double(pts.count), mx = pts.reduce(0) { $0 + $1.t } / n, my = pts.reduce(0) { $0 + $1.free } / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in pts { sxx += (p.t - mx) * (p.t - mx); sxy += (p.t - mx) * (p.free - my); syy += (p.free - my) * (p.free - my) }
        guard sxx > 0, syy > 0 else { return nil }
        let slope = sxy / sxx, fit = sxy * sxy / (sxx * syy)          // bytes a second; how well the days follow the line (0–1)
        let freeNow = Double(free ?? (diskInfo()["free"] as? Int64 ?? 0))
        guard slope < 0, fit >= 0.6, freeNow > 0 else { return nil }
        let left = freeNow / -slope / 86400
        guard left >= 1, left <= 60 else { return nil }
        // `line`: the days the forecast was drawn from (when, free bytes), for the chart
        return ["days": left.rounded(), "at": now + left * 86400, "perDay": (-slope * 86400).rounded(), "from": a.t, "points": pts.count,
                "line": pts.map { [$0.t, $0.free] }]
    }
}
