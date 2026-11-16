// Rumi — the JSON API the page already speaks, plus duplicates and trash.
import AppKit
import CryptoKit

private let thousands: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US"); return f
}()
func commas(_ n: Int) -> String { thousands.string(from: NSNumber(value: n)) ?? String(n) }

func diskInfo() -> [String: Any] {
    let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
    let total = Int64(v?.volumeTotalCapacity ?? 0)
    // "available for important usage" counts purgeable space, which is what Finder shows as available;
    // "available" is what's free this second. The difference is space macOS frees when it needs room.
    let now = Int64(v?.volumeAvailableCapacity ?? 0)
    var free = v?.volumeAvailableCapacityForImportantUsage ?? now
    if free <= 0 { free = now }
    return ["total": total, "used": total - free, "free": free, "freeNow": min(now, free), "purgeable": max(0, free - now)]
}

extension Store {
    func statusJSON() -> [String: Any] {
        progressLock.lock(); let seen = filesSeen, cur = current; progressLock.unlock()
        let disk = diskInfo()   // a volume query: keep it outside the lock the main thread also takes
        lock.lock(); defer { lock.unlock() }
        let end = finished > started ? finished : Date().timeIntervalSince1970
        return [
            "scanning": scanning, "files": seen, "current": cur.replacingOccurrences(of: HOME, with: "~"),
            "elapsed": started > 0 ? ((end - started) * 10).rounded() / 10 : 0,
            // a saved map counts as ready: the page shows it while a rescan runs quietly behind it
            "ready": root != nil, "loading": loading, "refreshing": scanning && root != nil, "saved": fromSaved,
            "scannedAt": root != nil ? finished : 0, "generation": generation, "since": root != nil ? baselineAt : 0,
            "disk": disk, "roots": roots, "home": HOME,
            "denied": denied.count, "access": access,
            "dupes": ["status": dupes.status, "progress": dupes.progress, "total": dupes.total, "rev": dupes.rev],
        ]
    }

    func toJSON(_ n: Dir, _ depth: Int) -> [String: Any] {
        var kids: [[String: Any]] = []
        if depth > 0 {
            enum Item { case d(Dir), f(FileRec) }
            var items: [(Int64, Item)] = n.dirs.map { ($0.size, .d($0)) } + n.files.map { ($0.alloc, .f($0)) }
            items.sort { $0.0 > $1.0 }
            let np = n.path
            for (_, it) in items.prefix(CHILD_LIMIT) {
                switch it {
                case .d(let d): kids.append(toJSON(d, depth - 1))
                case .f(let f):
                    var k: [String: Any] = ["name": f.name, "size": f.alloc, "type": "file", "cat": CATS[f.cat], "mtime": f.mtime,
                                            "path": n.parent != nil ? np + "/" + f.name : f.name]
                    if baselineAt > 0 { if f.was < 0 { k["new"] = true } else if f.alloc != f.was { k["d"] = f.alloc - f.was } }
                    kids.append(k)
                }
            }
            let rest = items.dropFirst(CHILD_LIMIT)
            let restSize = rest.reduce(Int64(0)) { $0 + $1.0 } + n.small
            let restN = rest.reduce(0) { acc, x in if case .d(let d) = x.1 { return acc + d.count }; return acc + 1 } + n.smallN
            if restSize > 0 { kids.append(["name": "\(commas(restN)) more items", "size": restSize, "type": "rest", "cat": "other"]) }
        }
        var out: [String: Any] = ["name": n.name, "path": n.parent != nil ? n.path : "", "size": n.size, "count": n.count, "type": "dir",
                "cat": CATS[n.cat], "mtime": n.mtime, "denied": n.denied, "pkg": n.pkg, "km": Int(n.kinds),
                "children": depth > 0 ? kids as Any : NSNull(), "hasKids": !n.dirs.isEmpty || !n.files.isEmpty]
        // since last time: new, or by how much it grew or shrank (the hover card says so)
        if baselineAt > 0 { if n.was < 0 { out["new"] = true } else if n.size != n.was { out["d"] = n.size - n.was } }
        // the stripe on a folder's label: its share of each category, in CATS order, out of 127
        if n.mix != 0 { out["mx"] = (0..<9).map { Int((n.mix >> UInt64($0 * 7)) & 127) } }
        return out
    }

    func treeJSON(path: String, depth: Int) -> (Int, [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        guard let top = root else { return (409, ["error": "not ready"]) }
        guard let n = path.isEmpty ? top : index[path] else { return (404, ["error": "not found"]) }
        var crumbs: [[String: Any]] = []
        var m: Dir? = n
        while let x = m {
            crumbs.append(["name": x.name.hasPrefix("/") ? x.name.replacingOccurrences(of: HOME, with: "~") : x.name,
                           "path": x.parent != nil ? x.path : ""])
            if x.name.hasPrefix("/") { crumbs.append(["name": "This Mac", "path": ""]); break }
            m = x.parent
        }
        return (200, ["node": toJSON(n, min(depth, 3)), "crumbs": Array(crumbs.reversed())])
    }

    func overviewJSON() -> (Int, [String: Any]) {
        let used = diskInfo()["used"] as? Int64 ?? 0   // a volume query: before the lock
        lock.lock(); defer { lock.unlock() }
        guard let top = root else { return (409, ["error": "not ready"]) }
        var cats: [String: Any] = [:]
        for (i, c) in CATS.enumerated() { cats[c] = catTotals[i] }
        // bigFiles is kept biggest first
        let biggest = bigFiles.prefix(60).map { ["path": $0.path, "size": $0.alloc, "mtime": $0.mtime, "cat": CATS[$0.cat]] as [String: Any] }
        var out: [String: Any] = ["cats": cats, "total": top.size, "biggest": Array(biggest), "denied": Array(denied.prefix(50))]
        if let c = Changes.summary(self, usedNow: used) { out["changes"] = c }
        return (200, out)
    }

    func dupesJSON() -> (Int, [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        guard root != nil else { return (409, ["error": "not ready"]) }
        return (200, ["status": dupes.status, "rev": dupes.rev, "groups": dupes.groups, "progress": dupes.progress, "total": dupes.total])
    }

    // MARK: suggestions

    func suggestionsJSON() -> (Int, [String: Any]) {
        let now = Date().timeIntervalSince1970
        var out: [[String: Any]] = []
        func add(_ group: String, _ title: String, _ why: String, _ path: String, _ size: Int64, _ safety: String, _ extra: [String: Any] = [:]) {
            guard size >= 20 * 1024 * 1024 else { return }
            var d: [String: Any] = ["group": group, "title": title, "why": why, "path": path, "size": size, "safety": safety]
            for (k, v) in extra { d[k] = v }
            out.append(d)
        }
        // The tree is read under the lock (a trash edits it). Only the slow lookups (app names, last-used dates) wait
        // until after: cache rows get their titles then, and apps are added last.
        lock.lock()
        guard root != nil else { lock.unlock(); return (409, ["error": "not ready"]) }
        let idx = index, big = bigFiles
        func get(_ rel: String) -> Dir? { idx[HOME + "/" + rel] }

        var cacheIDs: [String] = []
        if let caches = get("Library/Caches") {
            let mine: Set<String> = ["com.clinton.rumi", "StorageMap", "storage-map"]
            for ch in caches.dirs.sorted(by: { $0.size > $1.size }) where !mine.contains(ch.name) {
                if cacheIDs.count >= 25 { break }
                let n = out.count
                add("Caches", ch.name, "", ch.path, ch.size, "safe", ["kind": "dir"])
                if out.count > n { cacheIDs.append(ch.name) }
            }
        }
        for (rel, label) in [(".cache", ".cache"), (".npm", "npm cache"), ("Library/pnpm", "pnpm store"), (".gradle/caches", "Gradle cache")] {
            if let n = get(rel) { add("Caches", label, "", n.path, n.size, "safe", ["kind": "dir"]) }
        }
        // A virtual machine an app keeps in its data folder (a disk image of 2 GB or more) is often the biggest single thing
        // there, and some apps fetch it again when it's gone. Offered as the folder it sits in, one level into the app's own.
        let appData = HOME + "/Library/Application Support/"
        var machines = Set<String>()
        for b in big where b.alloc >= Int64(2) << 30 && b.path.hasPrefix(appData)
            && ["img", "qcow2", "vmdk", "vdi", "raw"].contains(fileExt((b.path as NSString).lastPathComponent)) {
            let parts = b.path.dropFirst(appData.count).split(separator: "/")
            if parts.count >= 3 { machines.insert(appData + parts[0] + "/" + parts[1]) }   // app / folder / … / image
        }
        for p in machines.sorted() {
            guard let d = idx[p] else { continue }
            let app = ((p as NSString).deletingLastPathComponent as NSString).lastPathComponent
            add("Caches", "\(app)'s virtual machine", "Quit \(app) first · it may download again", d.path, d.size, "review", ["kind": "dir"])
        }
        for (rel, label, why) in [
            ("Library/Developer/Xcode/DerivedData", "Xcode build files", "Rebuilt on your next build"),
            ("Library/Developer/Xcode/iOS DeviceSupport", "Old iPhone debugging files", "Come back when you plug in a device"),
            ("Library/Developer/Xcode/Archives", "Xcode archives", "Keep any you still ship"),
            ("Library/Developer/CoreSimulator/Devices", "iPhone simulators", "Their test data goes too"),
            ("Library/Application Support/MobileSync/Backup", "iPhone and iPad backups", "Keep any not in iCloud"),
        ] {
            if let n = get(rel) { add("Developer", label, why, n.path, n.size, label.contains("archive") || rel.contains("Backup") ? "review" : "safe", ["kind": "dir"]) }
        }
        for (p, n) in idx where ["node_modules", ".venv", "venv"].contains(n.name) && n.parent != nil {
            let head = String(p.dropLast(n.name.count))
            if head.contains("/node_modules/") || p.contains("/Library/") || p.contains(".app/") || head.replacingOccurrences(of: HOME, with: "").contains("/.") { continue }
            guard let proj = n.parent else { continue }
            let age = proj.mtime > 0 ? (now - proj.mtime) / 86400 : 999
            if age > 30 {
                add("Developer", "\(proj.name) · \(n.name)", "Untouched \(Int(age)) days · reinstalls", p, n.size, "safe", ["kind": "dir"])
            }
        }
        if let tr = get(".Trash") {
            add("Trash", "Trash", "", tr.path, tr.size, "safe", ["action": "empty"])
        }
        if let dl = get("Downloads") {
            let dp = dl.path
            for f in dl.files {
                let age = (now - f.mtime) / 86400
                let lower = f.name.lowercased()
                if [".dmg", ".pkg", ".xip", ".iso"].contains(where: { lower.hasSuffix($0) }) {
                    if let app = installedApp(forInstaller: f.name, idx["/Applications"]) {
                        add("Downloads", f.name, "\(app) is installed", dp + "/" + f.name, f.alloc, "safe")
                    } else {
                        add("Downloads", f.name, "App not installed", dp + "/" + f.name, f.alloc, "review")
                    }
                } else if age > 90 {
                    add("Downloads", f.name, "\(Int(age)) days old", dp + "/" + f.name, f.alloc, "review")
                }
            }
            for ch in dl.dirs {
                let age = ch.mtime > 0 ? (now - ch.mtime) / 86400 : 999
                if age > 90 { add("Downloads", ch.name, "Untouched \(Int(age)) days", ch.path, ch.size, "review", ["kind": "dir"]) }
            }
        }
        let seen = Set(out.compactMap { $0["path"] as? String })
        for b in big {   // biggest first
            if b.alloc < 300 * 1024 * 1024 { break }
            if !b.user || seen.contains(b.path) || b.path.contains("/Library/") || b.path.contains(".app/") { continue }
            let age = (now - b.mtime) / 86400
            if age > 180 {
                let kind = ["Video", "Photo", "Audio file", "Document", "Archive", "Developer file", "App file", "Cache file", "File"][b.cat]
                add("Large & old", (b.path as NSString).lastPathComponent, "\(kind) · \(Int(age / 30)) months old", b.path, b.alloc, "review")
            }
        }
        let apps = idx["/Applications"].map { a in a.dirs.sorted(by: { $0.size > $1.size }).prefix(12).filter { $0.name.hasSuffix(".app") }.map { ($0.name, $0.path, $0.size) } } ?? []
        lock.unlock()

        for (i, id) in cacheIDs.enumerated() { out[i]["title"] = cacheName(id) }   // the cache rows come first
        for (name, path, size) in apps {
            if let last = lastUsed(path), (now - last) / 86400 > 120 {
                add("Apps", String(name.dropLast(4)), "Unused \(Int((now - last) / 86400 / 30)) months", path, size, "review", ["kind": "app"])
            }
        }
        lock.lock(); suggested = Set(out.compactMap { $0["path"] as? String }); lock.unlock()
        return (200, ["items": out])
    }

    /// "com.example.player" → "Player". Apple's own caches are labelled as macOS.
    private func cacheName(_ id: String) -> String {
        if id.hasPrefix("com.apple.") { return "macOS · " + (id.split(separator: ".").last.map(String.init) ?? id) }
        if id.contains("."), !id.contains(" "), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        if id.contains("."), !id.contains(" "), let last = id.split(separator: ".").last { return last.prefix(1).uppercased() + last.dropFirst() }
        return id
    }

    /// "Example-1.2.dmg" → "Example" if /Applications has a matching app.
    private func installedApp(forInstaller name: String, _ apps: Dir?) -> String? {
        let stem = String(name.lowercased().split(whereSeparator: { "-_ .0123456789".contains($0) }).first ?? "")
        guard stem.count >= 3, let apps = apps else { return nil }
        return apps.dirs.first(where: { $0.name.hasSuffix(".app") && $0.name.lowercased().replacingOccurrences(of: " ", with: "").hasPrefix(stem) })
            .map { String($0.name.dropLast(4)) }
    }

    private func lastUsed(_ path: String) -> Double? {
        guard let item = NSMetadataItem(url: URL(fileURLWithPath: path)),
              let d = item.value(forAttribute: "kMDItemLastUsedDate") as? Date else { return nil }
        return d.timeIntervalSince1970
    }
}

// MARK: duplicates

private func isDataless(_ p: String) -> Bool {
    var st = stat()
    return lstat(p, &st) != 0 || st.st_flags & SF_DATALESS_FLAG != 0
}

func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}

// The throwing FileHandle calls: a read error (a disk going away, a file being rewritten) skips the file
// instead of raising an exception Swift can't catch.
private func partialHash(_ p: String, _ size: Int64) -> String? {
    guard let fh = FileHandle(forReadingAtPath: p) else { return nil }
    defer { try? fh.close() }
    var h = SHA256()
    do {
        h.update(data: try fh.read(upToCount: 65536) ?? Data())
        if size > 262144 {
            try fh.seek(toOffset: UInt64(size / 2)); h.update(data: try fh.read(upToCount: 65536) ?? Data())
            try fh.seek(toOffset: UInt64(max(0, size - 65536))); h.update(data: try fh.read(upToCount: 65536) ?? Data())
        }
    } catch { return nil }
    return hexString(h.finalize())
}

private func fullHash(_ p: String) -> String? {
    guard let fh = FileHandle(forReadingAtPath: p) else { return nil }
    defer { try? fh.close() }
    var h = SHA256()
    do {
        while let chunk = try autoreleasepool(invoking: { try fh.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            h.update(data: chunk)
        }
    } catch { return nil }
    return hexString(h.finalize())
}

/// The APFS clone family of a file, when it shares all its blocks with another file ("dev-id"), else nil.
/// Finder copies on the same disk are clones: trashing one of them frees nothing.
private func cloneFamily(_ p: String) -> String? {
    var st = stat()
    guard lstat(p, &st) == 0 else { return nil }
    var al = attrlist()
    al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
    al.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)
    // reply: u32 length, attribute_set_t (5 × u32: common, vol, dir, file, fork), u64 clone id, u32 extended flags
    var buf = [UInt8](repeating: 0, count: 64)
    guard getattrlist(p, &al, &buf, buf.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)) == 0 else { return nil }
    return buf.withUnsafeBytes { b -> String? in
        let fork = b.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
        guard fork & UInt32(ATTR_CMNEXT_CLONEID) != 0, fork & UInt32(ATTR_CMNEXT_EXT_FLAGS) != 0 else { return nil }
        let id = b.loadUnaligned(fromByteOffset: 24, as: UInt64.self), flags = b.loadUnaligned(fromByteOffset: 32, as: UInt32.self)
        guard id != 0, flags & UInt32(EF_SHARES_ALL_BLOCKS) != 0 else { return nil }
        return "\(st.st_dev)-\(id)"
    }
}

private let tailRx = try! NSRegularExpression(pattern: #"(\s*\(\d+\)|\s+copy(\s+\d+)?|[\s_-]+(final|edited|v\d+|\d{1,2}))$"#)
func normalizeName(_ name: String) -> String {
    let lower = name.lowercased()
    var stem = lower, ext = ""
    if let dot = lower.lastIndex(of: "."), dot != lower.startIndex { stem = String(lower[..<dot]); ext = String(lower[dot...]) }
    var prev = ""
    while prev != stem {
        prev = stem
        stem = tailRx.stringByReplacingMatches(in: stem, range: NSRange(stem.startIndex..., in: stem), withTemplate: "").trimmingCharacters(in: .whitespaces)
    }
    return stem + ext
}

func findDuplicates(gen: Int) {
    let S = Store.shared
    S.lock.lock()
    guard gen == S.generation else { S.lock.unlock(); return }
    S.dupes.status = "running"
    S.dupes.progress = 0
    HashMemo.shared.beginRun()
    let big = S.bigFiles
    S.dupesTrash = TrashLog(on: true)   // anything trashed from here on is left out when the groups publish
    S.lock.unlock()
    // never offer files that belong to an app, a library or a package
    func userFile(_ b: BigFile) -> Bool {
        b.user && !b.path.contains("/Library/") && !b.path.contains("/.") && !b.path.hasPrefix("/Applications/") && insidePackage(b.path) == nil
    }
    // folders that hold a code project (they have .git): copies there are usually on purpose
    S.lock.lock()
    let projects = Set(S.index.keys.filter { $0.hasSuffix("/.git") }.map { String($0.dropLast(5)) })
    S.lock.unlock()
    func inProject(_ p: String) -> Bool {
        var d = (p as NSString).deletingLastPathComponent
        while d.count > 1 { if projects.contains(d) { return true }; d = (d as NSString).deletingLastPathComponent }
        return false
    }
    var bySize: [Int64: [BigFile]] = [:]
    for b in big where userFile(b) { bySize[b.bytes, default: []].append(b) }
    let cands = bySize.values.filter { $0.count > 1 }
    S.lock.lock(); S.dupes.total = cands.reduce(0) { $0 + $1.count }; S.lock.unlock()
    var groups: [[String: Any]] = []
    var done = 0
    for g in cands {
        var byPart: [String: [BigFile]] = [:]
        for b in g where !isDataless(b.path) {
            let k = HashMemo.key(b.path, b.bytes, b.mtime)
            if let h = HashMemo.shared.cached(k, full: false) ?? partialHash(b.path, b.bytes) {
                HashMemo.shared.store(k, h, full: false); byPart[h, default: []].append(b)
            }
        }
        for sub in byPart.values where sub.count > 1 {
            var byFull: [String: [BigFile]] = [:]
            for b in sub {
                let k = HashMemo.key(b.path, b.bytes, b.mtime)
                if let h = b.bytes > (4 << 30) ? "sampled" : HashMemo.shared.cached(k, full: true) ?? fullHash(b.path) {
                    if h != "sampled" { HashMemo.shared.store(k, h, full: true) }
                    byFull[h, default: []].append(b)
                }
            }
            for (h, same0) in byFull where same0.count > 1 {
                let same = same0.sorted { $0.mtime < $1.mtime }   // oldest first = suggested keeper
                var files = same.map { ["path": $0.path, "size": $0.alloc, "mtime": $0.mtime] as [String: Any] }
                if h != "sampled" {
                    // copies that are clones of each other share their blocks: mark them, and they add no waste
                    let fam = same.map { cloneFamily($0.path) }
                    var n: [String: Int] = [:]
                    for f in fam { if let f = f { n[f, default: 0] += 1 } }
                    for (i, f) in fam.enumerated() { if let f = f, n[f]! > 1 { files[i]["clone"] = f } }
                }
                var g: [String: Any] = ["kind": h == "sampled" ? "similar" : "exact", "size": same[0].alloc, "project": same.contains { inProject($0.path) },
                                        "waste": Store.dupeWaste(files), "cat": CATS[same[0].cat], "files": files]
                if Store.cloneShared(files) { g["clones"] = true }
                groups.append(g)
            }
        }
        done += g.count
        S.lock.lock()
        if gen != S.generation { S.lock.unlock(); return }
        S.dupes.progress = done
        S.lock.unlock()
    }
    let exact = Set(groups.flatMap { ($0["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String } })
    var byName: [String: [BigFile]] = [:]
    for b in big where userFile(b) && !exact.contains(b.path) {
        // same folder only: board.png in five different projects are five different pictures
        byName[(b.path as NSString).deletingLastPathComponent + "/" + normalizeName((b.path as NSString).lastPathComponent), default: []].append(b)
    }
    for same0 in byName.values where same0.count >= 2 && same0.count <= 30 {
        let sizes = same0.map { $0.alloc }
        if sizes.max()! > 3 * sizes.min()! { continue }
        let same = same0.sorted { $0.mtime > $1.mtime }   // newest first = suggested keeper
        let files = same.map { ["path": $0.path, "size": $0.alloc, "mtime": $0.mtime] as [String: Any] }
        groups.append(["kind": "similar", "size": same[0].alloc, "project": same.contains { inProject($0.path) }, "waste": Store.dupeWaste(files),
                       "cat": CATS[same[0].cat], "files": files])
    }
    // files that went away while the check ran (deleted, or trashed: the trash log covers the last moments)
    groups = Store.prune(groups) { p in var st = stat(); return lstat(p, &st) != 0 }
    func byWaste(_ a: [String: Any], _ b: [String: Any]) -> Bool { (a["waste"] as? Int64 ?? 0) > (b["waste"] as? Int64 ?? 0) }
    groups.sort(by: byWaste)
    S.lock.lock()
    var finished: DupState?
    if gen == S.generation {
        let log = S.dupesTrash
        S.dupesTrash = TrashLog()
        if !log.paths.isEmpty || log.emptied { groups = Store.prune(groups, dropping: log.covers); groups.sort(by: byWaste) }
        S.dupes.groups = Array(groups.prefix(400)); S.dupes.status = "done"; S.dupes.rev += 1; finished = S.dupes
    }
    S.lock.unlock()
    if let d = finished { Snapshot.saveDupes(d) }
}

// MARK: trash, reveal, empty

/// `realpath(3)`: every link resolved, each name in its on-disk case. nil if it doesn't exist.
func realPath(_ p: String) -> String? {
    guard let r = realpath(p, nil) else { return nil }
    defer { free(r) }
    return String(cString: r)
}

/// The one spelling of a path that every check and action uses: absolute, no `.` or `..`, the folders above it with
/// links resolved and in their on-disk case (~/DOCUMENTS is ~/Documents). The last part isn't followed, so a link
/// stays a link. nil if it doesn't exist.
func canonicalPath(_ raw: String) -> String? {
    let p = (raw as NSString).standardizingPath
    var st = stat()
    guard p.hasPrefix("/"), lstat(p, &st) == 0 else { return nil }
    if p == "/" { return p }
    guard let parent = realPath((p as NSString).deletingLastPathComponent) else { return nil }
    let name = (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.nameKey]).name) ?? (p as NSString).lastPathComponent
    return (parent == "/" ? "" : parent) + "/" + name
}

private let scannedRoots = Store.shared.roots.map { realPath($0) ?? $0 }

/// The path, canonical, if it's one of the scanned folders or inside one; nil otherwise (or if it's gone).
/// `follow`: resolve a link at the end too, so it can't point out of the folders (for reading, not trashing).
func pathInRoots(_ raw: String, follow: Bool = false) -> String? {
    guard let p = follow ? realPath((raw as NSString).standardizingPath) : canonicalPath(raw) else { return nil }
    return rootOf(p, in: scannedRoots) != nil ? p : nil
}

/// Which of `roots` holds this path (or is it), if any. The one place that answers "is it under a root".
func rootOf(_ p: String, in roots: [String]) -> String? { roots.first { p == $0 || p.hasPrefix($0 + "/") } }

/// Whether a folder is one of the scanned folders itself (Home, Applications), links resolved.
func isScannedRoot(_ p: String) -> Bool { scannedRoots.contains(p) }

/// Places under ~ that can't be trashed, nor anything inside them. The page keeps the same list.
let PROTECTED_AREAS: [(String, String)] = [
    ("Library/Mobile Documents", "it's in iCloud Drive, where deleting reaches all your devices"),
    ("Library/CloudStorage", "it's in a synced cloud folder, where deleting reaches all your devices"),
    ("Library/Keychains", "it holds your passwords and keys"),
    ("Library/Mail", "it's Mail's own data. Remove mail from inside Mail"),
    ("Library/Messages", "it's Messages' own data. Remove chats from inside Messages"),
]

func safeToTrash(_ raw: String) -> (Bool, String) { let c = trashCheck(raw); return (c.path != nil, c.why) }

/// Whether a path may go to the Trash: its canonical path, or nil and why not.
func trashCheck(_ raw: String) -> (path: String?, why: String) {
    guard let p = canonicalPath(raw) else { return (nil, "no longer exists") }
    // a link, or a path through one, would trash whatever it points to
    if realPath(p) != p || p.lowercased() != (raw as NSString).standardizingPath.lowercased() { return (nil, "it's a shortcut to another place") }
    let protected = Set(["/", HOME, "/Applications"] + ["Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", ".Trash"].map { HOME + "/" + $0 })
    if protected.contains(p) { return (nil, "protected folder") }
    for (area, why) in PROTECTED_AREAS where p == HOME + "/" + area || p.hasPrefix(HOME + "/" + area + "/") { return (nil, why) }
    guard pathInRoots(p) != nil, !scannedRoots.contains(p) else { return (nil, "outside the scanned folders") }
    // Pieces of an app, framework or photo library: removing them breaks the whole thing.
    if let pkg = insidePackage(p) { return (nil, "it's part of \(pkg). Remove \(pkg) as a whole instead") }
    // Inside one app's data folder: only whole folders (an app you no longer use), or things Rumi suggested.
    for area in ["Library/Application Support", "Library/Containers", "Library/Group Containers"] {
        let base = HOME + "/" + area + "/"
        guard p.hasPrefix(base) else { continue }
        let depth = p.dropFirst(base.count).split(separator: "/").count
        Store.shared.lock.lock(); let ok = Store.shared.suggested.contains(p); Store.shared.lock.unlock()
        if depth > 1 && !ok {
            let app = p.dropFirst(base.count).split(separator: "/").first.map(String.init) ?? "an app"
            return (nil, "it's \(app)'s own data. Remove it from inside \(app), or remove the whole \(app) folder")
        }
    }
    return (p, "")
}

/// The package (app, framework, photo library…) a path sits inside, if any. The package itself doesn't count.
func insidePackage(_ p: String) -> String? {
    let parts = p.split(separator: "/").dropLast()
    let kinds = PKG_SUFFIXES + [".photolibrary", ".imovielibrary", ".musiclibrary", ".tvlibrary", ".logicx", ".band", ".xcarchive"]
    guard let hit = parts.first(where: { c in kinds.contains { c.lowercased().hasSuffix($0) } }) else { return nil }
    return String(hit).replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive, .anchored, .backwards])
}

/// Runs an AppleScript: (ok, error text, output).
func osascript(_ lines: [String], args: [String] = []) -> (Bool, String, String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = lines.flatMap { ["-e", $0] } + args
    let err = Pipe(), out = Pipe()
    task.standardError = err
    task.standardOutput = out
    do { try task.run() } catch { return (false, error.localizedDescription, "") }
    let o = out.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (task.terminationStatus == 0, msg.trimmingCharacters(in: .whitespacesAndNewlines),
            (String(data: o, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Show a file in Finder, selected in its folder (or open a folder), in a NEW Finder window on the given screen.
/// Asking Finder to "reveal" reuses a window that may be on another screen or desktop and takes you there; a new window
/// placed here doesn't. Falls back to the plain reveal if Finder can't be scripted.
@discardableResult
func showInFinder(_ path: String, select: Bool, on screen: NSScreen?) -> [Int] {
    guard FileManager.default.fileExists(atPath: path) else { return [] }
    let scr = screen ?? NSScreen.main ?? NSScreen.screens.first
    let vis = scr?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let primaryH = NSScreen.screens.first?.frame.height ?? vis.maxY   // Finder counts down from the top of the main display
    let w = min(960, vis.width - 80), h = min(620, vis.height - 80)
    let left = Int(vis.midX - w / 2), top = Int(primaryH - (vis.midY + h / 2))
    DispatchQueue.global(qos: .userInitiated).async {
        let (ok, _, _) = osascript([
            "on run argv", "set p to item 1 of argv",
            "set b to {(item 3 of argv) as integer, (item 4 of argv) as integer, (item 5 of argv) as integer, (item 6 of argv) as integer}",
            "tell application \"Finder\"", "set f to (POSIX file p) as alias",
            "if (item 2 of argv) is \"1\" then", "set w to make new Finder window to (container of f)", "else", "set w to make new Finder window to f", "end if",
            "set bounds of w to b", "if (item 2 of argv) is \"1\" then select f", "activate", "end tell", "end run",
        ], args: [path, select ? "1" : "0", String(left), String(top), String(left + Int(w)), String(top + Int(h))])
        if !ok {
            DispatchQueue.main.async {
                if select { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } else { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
        }
    }
    return [left, top, left + Int(w), top + Int(h)]
}

/// Finder does the deleting so "Put Back" works; if Finder refuses, fall back to the Trash API.
/// Returns where the item landed in the Trash, so Rumi can undo. A link is never followed.
func moveToTrash(_ p: String) -> (Bool, String, String?) {
    var st = stat(), err = ""
    guard lstat(p, &st) == 0 else { return (false, "no longer exists", nil) }
    if st.st_mode & S_IFMT != S_IFLNK {   // Finder's alias would resolve a link; the Trash API moves the link itself
        let (ok, e, out) = osascript(["on run argv", "tell application \"Finder\"", "set t to delete (POSIX file (item 1 of argv) as alias)",
                                      "return POSIX path of (t as alias)", "end tell", "end run"], args: [p])
        if ok { return (true, "", out.isEmpty ? nil : (out.hasSuffix("/") && out.count > 1 ? String(out.dropLast()) : out)) }
        err = e
    }
    var landed: NSURL?
    do { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &landed); return (true, "", landed?.path) }
    catch { return (false, String((err.isEmpty ? error.localizedDescription : err).prefix(200)), nil) }
}

/// What Move to Trash moved and where it landed ("from\0to", standardized). Undo accepts only these pairs.
private var undoable = Set<String>()
private let undoLock = NSLock()
private func undoKey(_ from: String, _ to: String) -> String { (from as NSString).standardizingPath + "\u{0}" + (to as NSString).standardizingPath }

/// Undo: move items back from the Trash to where they were, then refresh the map.
func putBackJSON(_ items: [[String: String]]) -> [String: Any] {
    var back = 0, problems: [String] = []
    for it in items.prefix(500) {
        let from = it["from"] ?? "", to = it["to"] ?? "", key = undoKey(from, to)
        let name = to.isEmpty ? "an item" : (to as NSString).lastPathComponent
        undoLock.lock(); let known = undoable.contains(key); undoLock.unlock()
        var st = stat()
        guard known else { problems.append(name + " wasn't moved by Rumi"); continue }
        if lstat(to, &st) == 0 { problems.append(name + " is already back"); continue }
        do {
            try FileManager.default.moveItem(atPath: from, toPath: to); back += 1
            undoLock.lock(); undoable.remove(key); undoLock.unlock()
        } catch { problems.append(name + ": " + error.localizedDescription) }
    }
    if back > 0 { Store.shared.startScan() }
    return ["ok": problems.isEmpty, "back": back, "error": problems.first ?? "", "problems": problems]
}

func trashJSON(_ paths: [String]) -> [String: Any] {
    let asked = Array(paths.prefix(500))
    // every duplicate set keeps a copy. Read the sets before anything moves: a trash drops a set once one copy is left.
    var sets: [String: [[String]]] = [:]
    Store.shared.lock.lock()
    for g in Store.shared.dupes.groups {
        let files = (g["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        for f in files { sets[f, default: []].append(files) }
    }
    Store.shared.lock.unlock()
    func exists(_ f: String) -> Bool { var st = stat(); return lstat(f, &st) == 0 }
    // copies go last, so a folder holding another copy has already moved when the copy is checked
    let copy = asked.map { sets[($0 as NSString).standardizingPath] != nil ? 1 : 0 }
    let order = asked.indices.sorted { (copy[$0], $0) < (copy[$1], $1) }
    var results = [[String: Any]](repeating: [:], count: asked.count)
    for i in order {
        var (path, why) = trashCheck(asked[i])
        var ok = false, landed: String?
        if let p = path, let groups = sets[p], groups.contains(where: { g in !g.contains { $0 != p && exists($0) } }) {
            why = "it's the last copy"
        } else if let p = path {
            var st = stat(); let size: Int64? = lstat(p, &st) == 0 ? Int64(st.st_blocks) * 512 : nil   // small files aren't in the tree: say how much left
            (ok, why, landed) = moveToTrash(p)
            if ok {
                Store.shared.lock.lock(); Store.shared.detach(p, size: size); Store.shared.lock.unlock()
                if let l = landed { undoLock.lock(); undoable.insert(undoKey(l, p)); undoLock.unlock() }
            }
        }
        var r: [String: Any] = ["path": path ?? asked[i], "ok": ok, "error": why]
        if let l = landed { r["trashed"] = l }
        results[i] = r
    }
    if results.contains(where: { $0["ok"] as? Bool == true }) { Snapshot.saveSoon() }   // so trashed files don't reappear next launch
    return ["results": results]
}

func emptyTrashJSON() -> [String: Any] {
    let (ok, err, _) = osascript(["tell application \"Finder\" to empty trash"])
    if ok { Store.shared.emptiedTrash(); Snapshot.saveSoon(); undoLock.lock(); undoable.removeAll(); undoLock.unlock() }
    return ["ok": ok, "error": String(err.prefix(200))]
}
