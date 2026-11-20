// Rumi — find by name. Two passes the page merges: Rumi's own map (folders and big files, instant, includes
// ~/Library) and Spotlight (every file by name, ~0.1–0.3 s, costs Rumi no memory). Plus the kinds list for the header filters.
import Foundation
import CoreServices

enum Search {
    static let queue = DispatchQueue(label: "rumi.search", qos: .userInitiated)
    private static var latest = ""
    private static let latestLock = NSLock()
    static func setLatest(_ q: String) { latestLock.lock(); latest = q; latestLock.unlock() }
    static func isLatest(_ q: String) -> Bool { latestLock.lock(); defer { latestLock.unlock() }; return latest == q }

    /// 0 exact name, 1 starts with it, 2 starts a word, 3 anywhere; +4 inside tool/cache folders nobody browses.
    static func score(_ name: String, _ path: String, _ q: String) -> Int? {
        let s: Int
        if let qb = asciiLower(q) {
            // the common case: compare bytes, folding A–Z (about 20× faster than a Foundation search over 150k names)
            guard let at = find(name, qb) else { return nil }
            let n = Array(name.utf8.prefix(at + qb.count + 1)), total = name.utf8.count
            if at == 0 {
                let after = name.utf8.dropFirst(qb.count)
                s = total == qb.count || (after.first == 46 && !after.dropFirst().contains(46)) ? 0 : 1
            } else { let c = n[at - 1]; s = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c >= 128 ? 3 : 2 }
        } else {
            guard let r = name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
            if r.lowerBound == name.startIndex { s = r.upperBound == name.endIndex ? 0 : 1 }
            else if let c = name[name.index(before: r.lowerBound)...].first, !c.isLetter && !c.isNumber { s = 2 } else { s = 3 }
        }
        if path.contains("/node_modules/") || path.contains("/Library/Caches/") || path.contains("/.") || path.contains("/Library/Containers/") { return s + 4 }
        return s
    }
    static func asciiLower(_ q: String) -> [UInt8]? {
        var out: [UInt8] = []; out.reserveCapacity(q.utf8.count)
        for b in q.utf8 { if b >= 128 { return nil }; out.append(b >= 65 && b <= 90 ? b + 32 : b) }
        return out.isEmpty ? nil : out
    }
    @inline(__always) static func find(_ name: String, _ q: [UInt8]) -> Int? {
        let hit = name.utf8.withContiguousStorageIfAvailable { n -> Int? in
            let N = n.count, M = q.count; guard M <= N else { return nil }
            let q0 = q[0]; var i = 0
            while i <= N - M {
                let b = n[i]
                if (b >= 65 && b <= 90 ? b + 32 : b) == q0 {
                    var j = 1
                    while j < M { let c = n[i + j]; if (c >= 65 && c <= 90 ? c + 32 : c) != q[j] { break }; j += 1 }
                    if j == M { return i }
                }
                i += 1
            }
            return nil
        }
        if let h = hit { return h }
        // not stored as contiguous UTF-8 (rare): copy once
        var s = name; s.makeContiguousUTF8(); return find(s, q)
    }

    static func row(_ path: String, _ name: String, _ size: Int64, dir: Bool, cat: Int, mtime: Double, pkg: Bool, score: Int) -> [String: Any] {
        ["path": path, "name": name, "size": size, "type": dir ? "dir" : "file", "cat": CATS[cat], "mtime": mtime, "pkg": pkg, "score": score]
    }

    /// Rumi's index: every folder, and files of 512 KB and up.
    static func index(_ q: String, limit: Int = 60) -> [[String: Any]] {
        let S = Store.shared
        S.lock.lock(); let idx = S.index; S.lock.unlock()
        // keep only (score, size, where) while scanning; build the rows for the winners
        // the file itself, not its position: a trash can change the folder's list before the rows are built
        var hits: [(Int, Int64, String, Dir, FileRec?)] = []   // nil = the folder itself
        for (p, d) in idx {
            if !p.isEmpty, let s = score(d.name, p, q) { hits.append((s, d.size, p, d, nil)) }
            for f in d.files { if let s = score(f.name, p, q) { hits.append((s, f.alloc, p, d, f)) } }
        }
        hits.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 > $1.1 }
        return hits.prefix(limit).map { (s, _, p, d, f) in
            guard let f = f else { return row(p, d.name, d.size, dir: true, cat: d.cat, mtime: d.mtime, pkg: d.pkg, score: s) }
            return row(p + "/" + f.name, f.name, f.alloc, dir: false, cat: f.cat, mtime: f.mtime, pkg: false, score: s)
        }
    }

    /// Spotlight, by file name, in Home and Applications.
    static func spotlight(_ q: String, limit: Int = 200) -> [[String: Any]] {
        let esc = q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "*", with: "\\*")
        guard let query = MDQueryCreate(kCFAllocatorDefault, "kMDItemFSName == \"*\(esc)*\"cd" as CFString, nil, nil) else { return [] }
        MDQuerySetSearchScope(query, [HOME, "/Applications"] as CFArray, 0)
        MDQuerySetMaxCount(query, limit)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        let S = Store.shared
        S.lock.lock(); let idx = S.index; S.lock.unlock()
        var out: [(Int, Int64, [String: Any])] = []
        for i in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let p = MDItemCopyAttribute(item, kMDItemPath) as? String, pathInRoots(p) != nil else { continue }
            let name = (p as NSString).lastPathComponent
            guard let s = score(name, p, q) else { continue }
            var st = stat(); guard lstat(p, &st) == 0 else { continue }
            let mt = Double(st.st_mtimespec.tv_sec)
            if st.st_mode & S_IFMT == S_IFDIR {
                let d = idx[p]
                out.append((s, d?.size ?? 0, row(p, name, d?.size ?? 0, dir: true, cat: d?.cat ?? CAT_OTHER, mtime: d?.mtime ?? mt, pkg: d?.pkg ?? PKG_SUFFIXES.contains { name.hasSuffix($0) }, score: s)))
            } else {
                let a = sharedAlloc(st)
                out.append((s, a, row(p, name, a, dir: false, cat: fileCat(name, nil), mtime: mt, pkg: false, score: s)))
            }
        }
        out.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 > $1.1 }
        return out.map { $0.2 }
    }

    /// Nothing typed yet (bigFiles is kept biggest first): your biggest files (not app data in ~/Library or hidden folders), as a place to start.
    static func biggest(_ n: Int = 6) -> [[String: Any]] {
        let S = Store.shared
        S.lock.lock(); let big = S.bigFiles; S.lock.unlock()
        return big.filter { $0.user && !$0.path.hasPrefix(HOME + "/Library/") && !$0.path.contains("/.") }.prefix(n).map {
            row($0.path, ($0.path as NSString).lastPathComponent, $0.alloc, dir: false, cat: $0.cat, mtime: $0.mtime, pkg: false, score: 9)
        }
    }

    static func kindsJSON() -> [String: Any] {
        let S = Store.shared
        S.lock.lock(); let t = S.kindTotals; S.lock.unlock()
        return ["kinds": KINDS.map { k -> [String: Any] in
            ["id": k.id, "label": k.label, "cat": CATS[k.cat], "exts": k.exts, "count": t.count > k.id * 2 + 1 ? t[k.id * 2] : 0, "bytes": t.count > k.id * 2 + 1 ? t[k.id * 2 + 1] : 0]
        }]
    }
}
