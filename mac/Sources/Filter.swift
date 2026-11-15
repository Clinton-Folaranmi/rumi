// Rumi — filters. A header filter ("Documents → Web pages") swaps the map for just the matching files inside the
// folder you're in, grouped by the folder they sit in. The kinds mask on every folder says where to look, so only
// folders that hold a match get listed; everything else is skipped without touching the disk.
import Foundation
import Darwin

enum Filter {
    struct Hit { let path: String; let name: String; let size: Int64; let mtime: Double; let cat: Int; let dir: Bool; let pkg: Bool }

    static let PER_GROUP = 60, TOP = 80   // the page keeps as many as fit with a readable name

    /// mask > 0: files of those kinds. mask == 0: a category without kinds (apps, caches, other) by what's in the index.
    static func json(path: String, mask: UInt32, cat: String) -> (Int, [String: Any]) {
        let S = Store.shared
        let ci = CATS.firstIndex(of: cat) ?? CAT_OTHER
        var hits: [Hit] = [], dirs: [String] = []
        // the tree walk only reads memory, so it runs under the lock (a trash edits the tree); the disk listing doesn't
        S.lock.lock()
        let top = S.root, n = path.isEmpty ? top : S.index[path], roots = S.roots
        if let scope = n { collect(scope, scope.parent != nil ? scope.path : "", mask, ci, &hits, &dirs) }
        S.lock.unlock()
        guard top != nil else { return (409, ["error": "not ready"]) }
        guard n != nil else { return (404, ["error": "not found"]) }
        if !dirs.isEmpty {
            let lock = NSLock(), W = min(4, dirs.count)
            DispatchQueue.concurrentPerform(iterations: W) { w in
                var mine: [Hit] = []
                var i = w; while i < dirs.count { list(dirs[i], mask, &mine); i += W }
                lock.lock(); hits += mine; lock.unlock()
            }
        }
        return (200, group(hits, scope: path, roots: roots, cat: cat, mask: mask))
    }

    private static func collect(_ d: Dir, _ p: String, _ mask: UInt32, _ ci: Int, _ hits: inout [Hit], _ dirs: inout [String]) {
        if mask != 0 {
            guard d.kinds & mask != 0 else { return }
            if !p.isEmpty { dirs.append(p) }
        } else {
            switch ci {
            case CAT_APP where d.name.hasSuffix(".app"):
                hits.append(Hit(path: p, name: d.name, size: d.size, mtime: d.mtime, cat: CAT_APP, dir: true, pkg: true)); return
            case CAT_CACHE where CACHE_DIRS.contains(d.name):
                hits.append(Hit(path: p, name: d.name, size: d.size, mtime: d.mtime, cat: CAT_CACHE, dir: true, pkg: false)); return
            default: break
            }
            if ci != CAT_APP && ci != CAT_CACHE {   // other: the big files the map keeps (512 KB and up)
                for f in d.files where f.cat == ci { hits.append(Hit(path: p + "/" + f.name, name: f.name, size: f.alloc, mtime: f.mtime, cat: ci, dir: false, pkg: false)) }
            }
        }
        for c in d.dirs { collect(c, c.name.hasPrefix("/") ? c.name : p + "/" + c.name, mask, ci, &hits, &dirs) }
    }

    /// One folder's own files whose extension is one of the kinds.
    private static func list(_ p: String, _ mask: UInt32, _ hits: inout [Hit]) {
        guard let dp = opendir(p) else { return }
        defer { closedir(dp) }
        let fd = dirfd(dp)
        while let e = readdir(dp) {
            guard e.pointee.d_type == DT_REG else { continue }
            let name = direntName(e)
            guard let k = KIND_OF[fileExt(name)], mask & (1 << UInt32(k)) != 0 else { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            hits.append(Hit(path: p + "/" + name, name: name, size: Int64(st.st_blocks) * 512,
                            mtime: Double(st.st_mtimespec.tv_sec), cat: KINDS[k].cat, dir: false, pkg: false))
        }
    }

    /// Group by the folder just below the scope. While everything sits in one folder, go one level deeper,
    /// so "This Mac" shows Downloads, Documents… rather than one big Home cartridge.
    private static func group(_ hits: [Hit], scope: String, roots: [String], cat: String, mask: UInt32) -> [String: Any] {
        let total = hits.reduce(Int64(0)) { $0 + $1.size }
        var base = scope
        if base.isEmpty, let r = roots.first(where: { r in hits.allSatisfy { rootOf($0.path, in: [r]) != nil && $0.path != r } }) { base = r }
        func key(_ h: Hit) -> String? {   // first folder below base, or nil if it sits right in base
            if base.isEmpty {
                guard let r = rootOf(h.path, in: roots), r != h.path else { return nil }
                let rest = h.path.dropFirst(r.count + 1)
                guard let slash = rest.firstIndex(of: "/") else { return nil }
                return r + "/" + rest[..<slash]
            }
            let rest = h.path.dropFirst(base.count + 1)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            return base + "/" + rest[..<slash]
        }
        var groups: [String: [Hit]] = [:], loose: [Hit] = []
        for _ in 0..<12 {
            groups = [:]; loose = []
            for h in hits { if let k = key(h) { groups[k, default: []].append(h) } else { loose.append(h) } }
            guard loose.isEmpty, groups.count == 1, let only = groups.keys.first else { break }
            base = only
        }
        func shown(_ p: String) -> String {   // a folder's name as seen from where you are
            var r = scope.isEmpty ? p : String(p.dropFirst(scope.count + 1))
            if scope.isEmpty && r.hasPrefix(HOME) { r = "~" + r.dropFirst(HOME.count) }
            return r
        }
        func fileJSON(_ h: Hit) -> [String: Any] {
            ["name": h.name, "path": h.path, "size": h.size, "type": h.dir ? "dir" : "file", "cat": CATS[h.cat], "mtime": h.mtime, "pkg": h.pkg, "hasKids": false]
        }
        func rest(_ items: ArraySlice<Hit>, _ label: String) -> [String: Any]? {
            items.isEmpty ? nil : ["name": "\(commas(items.count)) more \(label)", "size": items.reduce(Int64(0)) { $0 + $1.size }, "type": "rest", "cat": "other", "n": items.count]
        }
        enum Item { case g(String, [Hit], Int64), f(Hit) }
        var items: [Item] = groups.map { k, v in .g(k, v, v.reduce(Int64(0)) { $0 + $1.size }) } + loose.map { .f($0) }
        func sz(_ i: Item) -> Int64 { if case .g(_, _, let s) = i { return s }; if case .f(let h) = i { return h.size }; return 0 }
        func tucked(_ i: Item) -> Bool {
            guard case .g(let k, _, _) = i else { return false }
            return k.hasPrefix(HOME + "/Library") || k.contains("/.")
        }
        items.sort { tucked($0) != tucked($1) ? !tucked($0) : sz($0) > sz($1) }
        var kids: [[String: Any]] = []
        for it in items.prefix(TOP) {
            switch it {
            case .f(let h): kids.append(fileJSON(h))
            case .g(let k, let v, let s):
                let sorted = v.sorted { $0.size > $1.size }
                var inner = sorted.prefix(PER_GROUP).map(fileJSON)
                if var r = rest(sorted.dropFirst(PER_GROUP), "files") { r["open"] = k; inner.append(r) }
                kids.append(["name": shown(k), "path": k, "size": s, "count": v.count, "type": "dir", "cat": cat, "km": Int(mask),
                             "denied": false, "pkg": false, "hasKids": true, "children": inner, "matches": v.count])
            }
        }
        let left = items.dropFirst(TOP)
        if !left.isEmpty {
            let n = left.reduce(0) { a, i in if case .g(_, let v, _) = i { return a + v.count }; return a + 1 }
            kids.append(["name": "\(commas(n)) more", "size": left.reduce(Int64(0)) { $0 + sz($1) }, "type": "rest", "cat": "other", "n": n])
        }
        return ["count": hits.count, "bytes": total,
                "node": ["name": "matches", "path": scope, "size": total, "type": "dir", "cat": cat, "children": kids, "hasKids": !kids.isEmpty]]
    }
}
