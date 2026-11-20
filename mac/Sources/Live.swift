// Rumi — keeps the map current without rescanning the whole Mac (v2.0).
// macOS keeps a log of which folders changed (FSEvents). Rumi remembers where in that log its saved map stands, so on the
// next launch it asks for the folders that changed since, lists only those, and folds the result into the map. While the
// map is in memory the same thing happens every few seconds.
//
// What a live update can't know, and what happens instead:
// - Files under 512 KB are only a per-folder total, so a folder's small files keep its main category until a full scan,
//   and the kind totals only follow files the map keeps by name.
// - The log has gaps (history dropped, events lost, too many folders at once): full scan.
// A full scan also runs when the last one is a week old, so small drift never builds up.
import AppKit
import CoreServices

enum Live {
    static let FULL_EVERY: Double = 7 * 86400
    static let TOO_MANY = 30_000                 // changed folders in one go: a full scan is quicker and surer
    private static let q = DispatchQueue(label: "rumi.live", qos: .userInitiated)
    private static var stream: FSEventStreamRef?
    private static var pending = Set<String>()
    private static var lastEvent: UInt64 = 0     // the newest event among `pending`
    private static var history = false           // still replaying what happened before the stream started
    private static var scheduled = false
    private static var listedAt: [String: Date] = [:]   // big folders, and when each was last listed
    private static var holding = false                  // some changed big folders are waiting their turn
    private static var sweep = false                    // the next update lists them all, whenever they were last listed
    static let BIG = 4000, BIG_EVERY: Double = 300      // a folder with this many things in it is listed at most this often
    private static var saveTimer: DispatchSourceTimer?
    /// Bringing a saved map up to date (the page shows this like a quick refresh).
    private(set) static var catchingUp = false
    /// The stream is on and the map is level with it. (Written on the live queue, read anywhere.)
    private(set) static var current = false
    /// Test runs print what each update did.
    static var report: ((String) -> Void)?

    static var stateURL: URL { Snapshot.dir.appendingPathComponent("live.json") }
    static func eventNow() -> UInt64 { FSEventsGetCurrentEventId() }

    /// The file-system log's id for the volume the map is on. It changes when macOS starts the log over.
    private static func logID() -> String {
        var st = stat()
        guard lstat(HOME, &st) == 0, let u = FSEventsCopyUUIDForDevice(st.st_dev) else { return "" }
        return CFUUIDCreateString(nil, u) as String
    }

    // MARK: where the saved map stands

    /// Call right after the saved map is written (same queue, so the two files never disagree for long; if they do, the
    /// older position wins and a few folders are listed twice).
    static func save(event: UInt64, at: Double, full: Double) {
        let obj: [String: Any] = ["version": 1, "event": String(event), "log": logID(), "at": at, "full": full]
        Snapshot.writeQ.async { try? jsonData(obj).write(to: stateURL, options: .atomic) }
    }

    /// The event to replay from, if the saved map can be brought up to date that way.
    private static func resumePoint(mapAt: Double) -> UInt64? {
        guard let data = try? Data(contentsOf: stateURL), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["version"] as? Int == 1, let ev = UInt64(o["event"] as? String ?? ""), ev > 0, ev <= eventNow(),
              let log = o["log"] as? String, !log.isEmpty, log == logID(),
              let at = o["at"] as? Double, abs(at - mapAt) < 1,
              let full = o["full"] as? Double else { return nil }
        if Date().timeIntervalSince1970 - full >= FULL_EVERY { return nil }
        Store.shared.lock.lock(); Store.shared.liveFull = full; Store.shared.lock.unlock()
        return ev
    }

    // MARK: start and stop

    /// The map was just read from the saved file: bring it up to date from the log, or with a quiet full scan when the
    /// log can't be trusted for it.
    static func bringCurrent() {
        let S = Store.shared
        S.lock.lock()
        let loaded = S.root != nil, loading = S.loading, busy = S.scanning, mapAt = S.finished
        var from = S.liveEvent
        let age = Date().timeIntervalSince1970 - S.liveFull
        S.lock.unlock()
        if busy || S.access == "needed" || S.access == "misplaced" { return }
        if loading {   // the saved map is still being read: the page shows "updating" until this has run
            catchingUp = true
            return q.asyncAfter(deadline: .now() + 0.05) { bringCurrent() }
        }
        guard loaded else { catchingUp = false; S.startScan(quiet: true); return }   // nothing saved: scan
        if isFollowing { return }
        if from == 0 {   // just read from the file: the file beside it says where it stands
            guard let ev = resumePoint(mapAt: mapAt) else { catchingUp = false; S.startScan(quiet: true); return }
            from = ev
            S.lock.lock(); S.liveEvent = ev; S.lock.unlock()
            Changes.newDay(S, mapAt: mapAt)
        } else if age >= FULL_EVERY { catchingUp = false; S.startScan(quiet: true); return }
        catchingUp = true
        follow(since: from)
        // the replay normally ends within a second or two; a log that never answers shouldn't leave the map stale
        q.asyncAfter(deadline: .now() + 25) { if history, catchingUp { giveUp("the change log didn't answer") } }
    }
    private static var isFollowing = false   // a stream exists or is about to (set off the queue so two callers don't both start one)

    /// Watch the mapped folders from `since` on. Replaces any stream already running.
    static func follow(since: UInt64) {
        isFollowing = true
        q.async {
            let catching = catchingUp
            halt(); isFollowing = true; catchingUp = catching
            var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
            let cb: FSEventStreamCallback = { _, _, n, paths, flags, ids in
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                Live.got(list, flags: Array(UnsafeBufferPointer(start: flags, count: n)), ids: Array(UnsafeBufferPointer(start: ids, count: n)))
            }
            guard let s = FSEventStreamCreate(nil, cb, &ctx, Store.shared.roots as CFArray, since, 2.0,
                                              FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return }
            history = true; pending = []; lastEvent = since
            FSEventStreamSetDispatchQueue(s, q)
            FSEventStreamStart(s)
            stream = s
            if saveTimer == nil {   // live changes reach the saved file every few minutes, and when the map is let go
                let t = DispatchSource.makeTimerSource(queue: q)
                t.schedule(deadline: .now() + 300, repeating: 300)
                t.setEventHandler { Store.shared.lock.lock(); let dirty = Store.shared.liveDirty; Store.shared.lock.unlock(); if dirty { Snapshot.saveSoon() } }
                t.resume(); saveTimer = t
            }
        }
    }

    /// Stop watching (the map is being let go; the saved file knows where to resume).
    static func stop() { q.sync { halt() } }

    private static func halt() {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
        stream = nil; pending = []; history = false; scheduled = false; holding = false; sweep = false; catchingUp = false; current = false; isFollowing = false
    }

    private static func giveUp(_ why: String) {
        NSLog("Rumi: live updates fall back to a full scan (\(why))")
        report?("gave up: \(why)")
        halt()
        Store.shared.startScan(quiet: true)   // it starts a fresh stream when it lands
    }

    // MARK: events

    private static func got(_ paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
        let own = Snapshot.dir.path
        for (i, raw) in paths.enumerated() {
            let f = Int(flags[i])
            if f & kFSEventStreamEventFlagHistoryDone != 0 { history = false; continue }   // `current` turns true once this is folded in
            if f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0 {
                return giveUp("the log skipped something")
            }
            if f & (kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 { continue }
            var p = raw.hasPrefix("/System/Volumes/Data/") ? String(raw.dropFirst(20)) : raw
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            if p == own || p.hasPrefix(own + "/") { continue }   // Rumi's own saves
            pending.insert(p)
            if ids[i] > lastEvent { lastEvent = ids[i] }
        }
        if pending.count > TOO_MANY { return giveUp("\(pending.count) folders changed") }
        if history || scheduled { return }
        scheduled = true
        // right away when catching up; otherwise let a burst of changes settle into one update
        q.asyncAfter(deadline: .now() + (catchingUp ? 0 : 3)) { flush() }
    }

    private static func flush() {
        scheduled = false
        guard stream != nil else { return }
        let S = Store.shared
        S.lock.lock(); let busy = S.scanning || S.root == nil; S.lock.unlock()
        if busy { return }   // a full scan is running: it replays from its own start when it lands
        let paths = pending, upTo = lastEvent, first = catchingUp
        pending = []
        let t0 = Date()
        // a folder with thousands of files in it (a browser's cache changes all day) waits its turn. Catching up does the
        // ordinary folders first, so the map is current in a moment, then every big one straight after (`sweep`)
        let all = sweep; sweep = false
        let r = S.applyLive(paths) { path, entries in
            guard entries >= BIG else { return true }
            if first { return false }
            if !all, let at = listedAt[path], t0.timeIntervalSince(at) < BIG_EVERY { return false }
            listedAt[path] = t0; return true
        }
        guard r.done else { pending.formUnion(paths); return }   // a scan started meanwhile: it replays from its own start
        // the saved map may only claim to be level with the log when nothing is waiting
        pending.formUnion(r.held); holding = !r.held.isEmpty
        S.liveNow(upTo: holding ? 0 : upTo)
        if first, holding { sweep = true }
        if holding, !scheduled { scheduled = true; q.asyncAfter(deadline: .now() + (first ? 0.1 : 60)) { flush() } }
        catchingUp = false; current = true
        if first || r.moved > 0 { report?("\(first ? "caught up" : "update"): \(paths.count) changed, \(r.listed) listed, \(r.held.count) waiting, \(r.added) new, \(r.removed) gone, moved \(r.moved) bytes, \(String(format: "%.2f", Date().timeIntervalSince(t0))) s") }
        if first { NSLog("Rumi: caught up with \(paths.count) changed folders in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s"); Snapshot.saveSoon(); History.sample(force: true) }
        if !first, r.moved > 0 { DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.mapMoved(r.moved) } }
    }
}

// MARK: folding changed folders into the map

/// One folder as it is on disk right now: its own files, and the names of its subfolders.
private struct Listing {
    var files: [FileRec] = [], small: Int64 = 0, smallN = 0, mtime: Double = 0, kinds: UInt32 = 0
    var big: [BigFile] = []                              // its files of 1 MB and up, for the Biggest list
    var dirs: [(name: String, dataless: Bool)] = []
    var gone = false, denied = false
    var fresh: [(dir: Dir, found: Store.Found)] = []     // subfolders the map didn't have, scanned whole
}

private struct Target { let dir: Dir; let path: String; let ctx: Int?; let had: Set<String> }

extension Store {
    struct LiveResult { var listed = 0, added = 0, removed = 0; var moved: Int64 = 0; var held: [String] = []; var done = false }

    /// The nine category sizes a folder's stripe stands for (the stripe keeps shares, not bytes).
    private func cats(of d: Dir) -> [Int64] {
        var shares = [Int64](repeating: 0, count: 9), sum: Int64 = 0
        for j in 0..<9 { shares[j] = Int64((d.mix >> UInt64(j * 7)) & 127); sum += shares[j] }
        guard sum > 0 else { var v = shares; v[d.cat] = d.size; return v }
        return shares.map { Int64(Double(d.size) * Double($0) / Double(sum)) }
    }

    /// Move a folder's main category and stripe by `dv` bytes per category. Call before its size changes.
    private func shift(_ d: Dir, by dv: [Int64]) {
        var v = cats(of: d)
        for j in 0..<9 { v[j] = max(0, v[j] + dv[j]) }
        guard let mx = v.max(), mx > 0, let i = v.firstIndex(of: mx) else { d.cat = CAT_OTHER; d.mix = 0; return }
        d.cat = i
        let total = Double(v.reduce(0, +))
        var m: UInt64 = 0
        for (j, x) in v.enumerated() where x > 0 { m |= UInt64(max(1, (Double(x) / total * 127).rounded())) << UInt64(j * 7) }
        d.mix = m
    }

    /// Sizes are read the way the scanner reads them (one stat per file), so the two always agree.
    private func read(_ t: Target, dev: dev_t) -> Listing {
        var L = Listing()
        guard let dp = opendir(t.path) else { if errno == ENOENT || errno == ENOTDIR { L.gone = true } else { L.denied = true }; return L }
        defer { closedir(dp) }
        let fd = dirfd(dp)
        var names: [String] = []
        while let ent = readdir(dp) {
            let name = direntName(ent)
            if name != ".", name != "..", ent.pointee.d_type != UInt8(DT_LNK) { names.append(name) }
        }
        func part(_ r: Range<Int>) -> Listing {
            var P = Listing()
            for name in names[r] {
                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let mode = st.st_mode & S_IFMT
                if mode == S_IFLNK { continue }
                if mode == S_IFDIR {
                    if st.st_dev == dev { P.dirs.append((name, st.st_flags & SF_DATALESS_FLAG != 0)) }
                    continue
                }
                let alloc = sharedAlloc(st), ext = fileExt(name), c = t.ctx ?? (EXT[ext] ?? CAT_OTHER)
                if t.ctx == nil, let k = KIND_OF[ext] { P.kinds |= 1 << UInt32(k) }
                let mt = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
                if mt > P.mtime { P.mtime = mt }
                if alloc >= KEEP_FILE_MIN {
                    P.files.append(FileRec(name: name, alloc: alloc, bytes: Int64(st.st_size), mtime: mt, cat: c))
                    if alloc >= DUP_MIN { P.big.append(BigFile(path: t.path + "/" + name, alloc: alloc, bytes: Int64(st.st_size), mtime: mt, cat: c, user: t.ctx == nil)) }
                } else { P.small += alloc; P.smallN += 1 }
            }
            return P
        }
        if names.count < 2048 { return part(0..<names.count) }
        // a folder with thousands of files (a browser's cache): several threads share the work
        let n = 8, step = (names.count + n - 1) / n
        var parts = [Listing](repeating: Listing(), count: n)
        parts.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: n) { i in out[i] = part(min(i * step, names.count)..<min((i + 1) * step, names.count)) }
        }
        for P in parts {
            L.files += P.files; L.small += P.small; L.smallN += P.smallN; L.kinds |= P.kinds; L.big += P.big; L.dirs += P.dirs
            if P.mtime > L.mtime { L.mtime = P.mtime }
        }
        return L
    }

    /// List the folders that changed and fold them into the map. `mayList` is asked about each one (with how many
    /// things the map has in it) and can hold it back for later; those come back in `held`.
    /// Runs on the live queue only, and never while a full scan runs.
    func applyLive(_ paths: Set<String>, mayList: (String, Int) -> Bool) -> LiveResult {
        var R = LiveResult()
        // 1. which folders on the map these are (a path the map doesn't have stands for the nearest folder above it that it does)
        lock.lock()
        guard root != nil, !scanning else { lock.unlock(); return R }
        var targets: [String: Target] = [:]
        for raw in paths {
            var p = raw
            while index[p] == nil, p.count > 1, !roots.contains(p) { p = (p as NSString).deletingLastPathComponent }
            guard targets[p] == nil, let d = index[p] else { continue }
            guard mayList(p, d.files.count + d.smallN + d.dirs.count) else { R.held.append(p); continue }
            targets[p] = Target(dir: d, path: p, ctx: context(of: d), had: Set(d.dirs.map(\.name)))
        }
        lock.unlock()
        var st = stat()
        guard !targets.isEmpty, lstat(HOME, &st) == 0 else { R.done = true; return R }
        let dev = st.st_dev

        // 2. read them (no lock: this is the slow part), then scan any subfolder the map didn't have
        let list = Array(targets.values)
        var listings = [Listing](repeating: Listing(), count: list.count)
        listings.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: list.count) { i in out[i] = read(list[i], dev: dev) }
        }
        for i in list.indices {
            let t = list[i]
            for sub in listings[i].dirs where !t.had.contains(sub.name) {
                let child = Dir(name: sub.name, parent: nil)
                var found = Found(kinds: [Int64](repeating: 0, count: KINDS.count * 2), cats: [Int64](repeating: 0, count: 9))
                if !sub.dataless {   // cloud placeholder folders are listed but never opened
                    found = scan(child, jobs: [Work(dir: child, path: t.path + "/" + sub.name, ctx: dirContext(sub.name, t.ctx), dev: dev)], workers: 4, background: false)
                }
                listings[i].fresh.append((child, found))
            }
        }

        // 3. fold them in
        lock.lock()
        guard root != nil, !scanning else { lock.unlock(); return R }
        var changed = Set<String>(), newBig: [BigFile] = []
        for i in list.indices {
            let t = list[i], L = listings[i], d = t.dir
            guard index[t.path] === d else { continue }   // trashed or replaced meanwhile
            if L.gone { if !roots.contains(t.path), detachNow(t.path, size: nil) { R.removed += 1 }; continue }
            if L.denied { continue }
            R.listed += 1
            let bucket = t.ctx ?? d.cat   // where this folder's small files are charged (see Store.forget)

            // what changes, by category: subfolders gone, its own files, subfolders new
            let onDisk = Set(L.dirs.map(\.name))
            let goneDirs = d.dirs.filter { !onDisk.contains($0.name) }
            var own = [Int64](repeating: 0, count: 9), dv = [Int64](repeating: 0, count: 9)
            for f in d.files { own[f.cat] -= f.alloc }
            for f in L.files { own[f.cat] += f.alloc }
            own[bucket] += L.small - d.small
            for j in 0..<9 { dv[j] = own[j] }
            for g in goneDirs { let v = cats(of: g); for j in 0..<9 { dv[j] -= v[j] } }
            for f in L.fresh { for j in 0..<9 { dv[j] += f.found.cats[j] } }
            var n: Dir? = d
            while let m = n { shift(m, by: dv); n = m.parent }

            // subfolders that are gone
            for g in goneDirs {
                let gp = t.path + "/" + g.name
                R.moved += g.size
                if detachNow(gp, size: nil) { R.removed += 1 }
                if !denied.isEmpty { denied.removeAll { $0 == gp || $0.hasPrefix(gp + "/") } }
            }

            // its own files
            var dSize: Int64 = 0, dCount = 0
            var was: [String: Int64] = [:]
            for f in d.files { was[f.name] = f.was }
            var files = L.files
            for k in files.indices {
                if let w = was.removeValue(forKey: files[k].name) { files[k].was = w }
                else if let gi = d.gone.firstIndex(where: { !$0.dir && $0.name == files[k].name }) { files[k].was = d.gone[gi].size; d.gone.remove(at: gi) }
            }
            if baselineAt > 0 { for f in d.files where was[f.name] != nil && f.was >= 0 { d.gone.append(Gone(name: f.name, size: f.was, dir: false, cat: f.cat)) } }
            if t.ctx == nil {   // kind totals follow the files the map keeps by name
                for f in d.files { if let k = KIND_OF[fileExt(f.name)] { kindTotals[k * 2] = max(0, kindTotals[k * 2] - 1); kindTotals[k * 2 + 1] = max(0, kindTotals[k * 2 + 1] - f.alloc) } }
                for f in files { if let k = KIND_OF[fileExt(f.name)] { kindTotals[k * 2] += 1; kindTotals[k * 2 + 1] += f.alloc } }
            }
            dSize = files.reduce(0) { $0 + $1.alloc } + L.small - d.files.reduce(0) { $0 + $1.alloc } - d.small
            dCount = files.count + L.smallN - d.files.count - d.smallN
            d.files = files; d.small = L.small; d.smallN = L.smallN
            for j in 0..<9 { catTotals[j] = max(0, catTotals[j] + own[j]) }
            changed.insert(t.path); newBig += L.big
            if t.path == HOME + "/.Trash" { trashedSince = 0 }   // the map's Bin is exact again
            R.moved += abs(dSize)

            // subfolders the map didn't have
            var kinds = L.kinds, mtime = L.mtime
            for f in L.fresh {
                let c = f.dir
                c.parent = d; d.dirs.append(c)
                if let gi = d.gone.firstIndex(where: { $0.dir && $0.name == c.name }) { c.was = d.gone[gi].size; d.gone.remove(at: gi) }
                var walk: [(Dir, String)] = [(c, t.path + "/" + c.name)]
                while let (x, p) = walk.popLast() { index[p] = x; for y in x.dirs { walk.append((y, p + "/" + y.name)) } }
                for j in 0..<9 { catTotals[j] += f.found.cats[j] }
                for j in kindTotals.indices where j < f.found.kinds.count { kindTotals[j] += f.found.kinds[j] }
                newBig += f.found.big; denied += f.found.denied
                dSize += c.size; dCount += c.count; kinds |= c.kinds; mtime = max(mtime, c.mtime)
                R.added += 1; R.moved += c.size
            }
            n = d
            while let m = n { m.size += dSize; m.count += dCount; m.kinds |= kinds; if mtime > m.mtime { m.mtime = mtime }; n = m.parent }
        }
        // the Biggest list and the duplicate groups: out with what these folders held, in with what they hold now
        if !changed.isEmpty {
            var old: [String: BigFile] = [:]
            bigFiles.removeAll { b in
                guard changed.contains((b.path as NSString).deletingLastPathComponent) else { return false }
                old[b.path] = b; return true
            }
            let now = Dictionary(newBig.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            let stale = Set(old.filter { now[$0.key]?.bytes != $0.value.bytes || now[$0.key]?.mtime != $0.value.mtime }.keys)
            if !stale.isEmpty { dupes.groups = Store.prune(dupes.groups) { stale.contains($0) } }
        }
        if !newBig.isEmpty { bigFiles += newBig; bigFiles.sort { $0.alloc > $1.alloc } }
        if R.moved > 0 || R.added + R.removed > 0 { churnStale = true }
        R.done = true
        lock.unlock()
        return R
    }

    /// The map now holds every change up to `event` (0: leave where it stands as it is).
    func liveNow(upTo event: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard root != nil, !scanning else { return }
        finished = Date().timeIntervalSince1970
        if event > liveEvent { liveEvent = event }
        liveDirty = true
    }
}

// MARK: test runs

extension Store {
    /// Scan everything afresh and say where the live map disagrees with it (folder by folder, each folder's own files).
    func liveCheck() -> String {
        let top = Dir(name: "This Mac", parent: nil)
        let found = scan(top, jobs: rootJobs(top), workers: 8, background: false)
        let fresh = Store.buildIndex(top)
        func own(_ d: Dir) -> Int64 { d.files.reduce(d.small) { $0 + $1.alloc } }
        lock.lock(); defer { lock.unlock() }
        guard let live = root else { return "live check: no map" }
        var off: [(String, Int64)] = [], missing = 0, extra = 0
        for (p, d) in index {
            guard let f = fresh[p] else { extra += 1; off.append((p, own(d))); continue }
            if own(f) != own(d) { off.append((p, own(d) - own(f))) }
        }
        for (p, f) in fresh where index[p] == nil { missing += 1; off.append((p, -own(f))) }
        off.sort { abs($0.1) > abs($1.1) }
        var out = "live check: map \(live.size) vs fresh \(top.size) (\(live.size - top.size)); files \(live.count) vs \(top.count); folders \(index.count) vs \(fresh.count)\n"
        out += "live check: \(off.count) folders differ (\(extra) only on the live map, \(missing) only in the fresh scan), \(off.reduce(Int64(0)) { $0 + abs($1.1) }) bytes apart in all\n"
        out += "live check: categories apart " + zip(catTotals, found.cats).map { String($0 - $1) }.joined(separator: " ") + "\n"
        for (p, d) in off.prefix(12) { out += "  \(d)  \(p.replacingOccurrences(of: HOME, with: "~"))\n" }
        return out
    }
}
