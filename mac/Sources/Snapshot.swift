// Rumi — remembers the last scan between launches.
// The folder tree is written to a small binary file after every scan (and after Move to Trash), and read back
// at launch so the map opens instantly; a quiet rescan then runs in the background and swaps in when done.
// Duplicate groups and file fingerprints are kept beside it so the duplicate check doesn't re-read every file.
import Foundation

enum Snapshot {
    static let dir: URL = {
        // Application Support, not Caches: Rumi's own clean-up suggests emptying Caches folders.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("com.clinton.rumi", isDirectory: true)
        // test runs can keep their saved scans somewhere else, so they never touch the real ones
        if DEV_MODE || CommandLine.arguments.contains("--bench"), let alt = ProcessInfo.processInfo.environment["RUMI_DATA_DIR"], !alt.isEmpty {
            d = URL(fileURLWithPath: alt, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static var treeURL: URL { dir.appendingPathComponent("last-scan.bin") }
    static var dupesURL: URL { dir.appendingPathComponent("duplicates.json") }
    /// The scan the map is compared against ("since last time"): a copy of an earlier last-scan.bin. See Changes.swift.
    static var baselineURL: URL { dir.appendingPathComponent("baseline.bin") }
    static var historyURL: URL { dir.appendingPathComponent("history.json") }
    static let MAGIC: UInt32 = 0x524D_4931   // "RMI1"
    static let VERSION: UInt32 = 4           // 2: kinds. 3: what each folder and file was at the comparison scan. 4: each folder's mix of categories
    static let writeQ = DispatchQueue(label: "rumi.snapshot", qos: .utility)

    // MARK: write

    /// Serialize a tree. The caller makes sure nothing mutates it meanwhile.
    static func encode(top: Dir, roots: [String], scannedAt: Double, files: Int, big: [BigFile], cats: [Int64], denied: [String], kinds: [Int64],
                       baselineAt: Double = 0, baseUsed: Int64 = -1) -> Data {
        var w = Writer()
        w.u32(MAGIC); w.u32(VERSION)
        w.f64(scannedAt); w.u64(UInt64(files))
        w.f64(baselineAt); w.i64(baseUsed)
        w.u32(UInt32(roots.count)); roots.forEach { w.str($0) }
        cats.forEach { w.i64($0) }
        w.u32(UInt32(kinds.count)); kinds.forEach { w.i64($0) }
        w.u32(UInt32(denied.count)); denied.forEach { w.str($0) }
        w.u32(UInt32(big.count))
        for b in big { w.str(b.path); w.i64(b.alloc); w.i64(b.bytes); w.f64(b.mtime); w.u8(UInt8(b.cat)); w.u8(b.user ? 1 : 0) }
        // pre-order: each folder, then its subfolders' subtrees in order
        var stack = [top]
        while let d = stack.popLast() {
            w.str(d.name); w.i64(d.size); w.i64(Int64(d.count)); w.i64(d.small); w.i64(Int64(d.smallN))
            w.u8(UInt8(d.cat)); w.f64(d.mtime); w.u8((d.denied ? 1 : 0) | (d.pkg ? 2 : 0)); w.u32(d.kinds)
            w.i64(d.was); w.i64(d.wasSmall); w.u64(d.mix)
            w.u32(UInt32(d.gone.count))
            for g in d.gone { w.str(g.name); w.i64(g.size); w.u8(g.dir ? 1 : 0); w.u8(UInt8(g.cat)) }
            w.u32(UInt32(d.files.count))
            for f in d.files { w.str(f.name); w.i64(f.alloc); w.i64(f.bytes); w.f64(f.mtime); w.u8(UInt8(f.cat)); w.i64(f.was) }
            w.u32(UInt32(d.dirs.count))
            stack.append(contentsOf: d.dirs.reversed())
        }
        return w.data
    }

    static func write(_ data: Data) {
        writeQ.async {
            do { try data.write(to: treeURL, options: .atomic) }
            catch { NSLog("Rumi: couldn't save the scan: \(error)") }
        }
    }

    /// Save the current tree (after trash edits). Debounced so a batch of trashes writes once.
    private static var pendingSave: DispatchWorkItem?
    static func saveSoon() {
        DispatchQueue.main.async {
            pendingSave?.cancel()
            let item = DispatchWorkItem {
                let S = Store.shared
                S.lock.lock()
                guard let top = S.root, !S.scanning else { S.lock.unlock(); return }   // a running scan will save its own
                let data = encode(top: top, roots: S.roots, scannedAt: S.finished, files: top.count, big: S.bigFiles, cats: S.catTotals, denied: S.denied, kinds: S.kindTotals,
                                  baselineAt: S.baselineAt, baseUsed: S.baseUsed)
                let dupes = S.dupes
                S.lock.unlock()
                write(data)
                saveDupes(dupes)
            }
            pendingSave = item
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5, execute: item)
        }
    }

    static func saveDupes(_ d: DupState) {
        guard d.status == "done" else { return }
        let obj: [String: Any] = ["version": 1, "groups": d.groups, "memo": HashMemo.shared.export()]
        writeQ.async { try? jsonData(obj).write(to: dupesURL, options: .atomic) }
    }

    // MARK: read

    struct Loaded {
        let top: Dir; let scannedAt: Double; let big: [BigFile]; let cats: [Int64]; let denied: [String]; var kinds: [Int64] = []
        var baselineAt: Double = 0; var baseUsed: Int64 = -1
    }

    /// When a saved scan was made, read from its first bytes (nil: no file, or not one of ours).
    static func scannedAt(_ url: URL) -> Double? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let d = try? fh.read(upToCount: 16), d.count == 16 else { return nil }
        return d.withUnsafeBytes { raw -> Double? in
            var r = Reader(raw)
            guard r.u32() == MAGIC else { return nil }
            let ver = r.u32(); guard ver >= 1, ver <= VERSION else { return nil }
            return r.f64()
        }
    }

    static func load(roots: [String], from url: URL = treeURL) -> Loaded? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return data.withUnsafeBytes { raw -> Loaded? in
            var r = Reader(raw)
            guard r.u32() == MAGIC else { return nil }
            let ver = r.u32(); guard ver >= 1, ver <= VERSION else { return nil }
            let scannedAt = r.f64(); _ = r.u64()   // file count (the tree carries it)
            var baselineAt: Double = 0, baseUsed: Int64 = -1
            if ver >= 3 { baselineAt = r.f64(); baseUsed = r.i64() }
            let nr = Int(r.u32()); guard nr < 100 else { return nil }
            let savedRoots = (0..<nr).map { _ in r.str() }
            guard savedRoots == roots else { return nil }   // scanned different folders: start fresh
            let cats = (0..<9).map { _ in r.i64() }
            var kinds: [Int64] = []
            if ver >= 2 { let nk = Int(r.u32()); guard nk < 1000 else { return nil }; kinds = (0..<nk).map { _ in r.i64() } }
            let nd = Int(r.u32()); guard nd < 10_000_000 else { return nil }
            let denied = (0..<nd).map { _ in r.str() }
            // counts can't exceed what the bytes left could hold (a big file takes at least 30, a file 29)
            let nb = Int(r.u32()); guard nb <= r.left / 30 else { return nil }
            var big: [BigFile] = []; big.reserveCapacity(nb)
            for _ in 0..<nb {
                let p = r.str(), a = r.i64(), b = r.i64(), m = r.f64(), c = Int(r.u8()), u = r.u8() == 1
                big.append(BigFile(path: p, alloc: a, bytes: b, mtime: m, cat: min(c, 8), user: u))
            }
            func node(_ parent: Dir?) -> (Dir, Int) {
                let d = Dir(name: r.str(), parent: parent)
                d.size = r.i64(); d.count = Int(r.i64()); d.small = r.i64(); d.smallN = Int(r.i64())
                d.cat = min(Int(r.u8()), 8); d.mtime = r.f64()
                let fl = r.u8(); d.denied = fl & 1 != 0; d.pkg = fl & 2 != 0
                if ver >= 2 { d.kinds = r.u32() }
                if ver >= 3 {
                    d.was = r.i64(); d.wasSmall = r.i64()
                    if ver >= 4 { d.mix = r.u64() }
                    let ng = Int(r.u32())
                    if ng > r.left / 14 { r.bad = true } else if ng > 0 {
                        d.gone.reserveCapacity(ng)
                        for _ in 0..<ng { d.gone.append(Gone(name: r.str(), size: r.i64(), dir: r.u8() == 1, cat: min(Int(r.u8()), 8))) }
                    }
                }
                d.catv = nil
                let nf = Int(r.u32())
                if nf > r.left / 29 { r.bad = true } else if nf > 0 {
                    d.files.reserveCapacity(nf)
                    for _ in 0..<nf {
                        var f = FileRec(name: r.str(), alloc: r.i64(), bytes: r.i64(), mtime: r.f64(), cat: min(Int(r.u8()), 8))
                        if ver >= 3 { f.was = r.i64() }
                        d.files.append(f)
                    }
                }
                return (d, Int(r.u32()))
            }
            let (top, n0) = node(nil)
            var stack: [(Dir, Int)] = [(top, n0)]
            while !stack.isEmpty, !r.bad {
                if stack[stack.count - 1].1 == 0 { stack.removeLast(); continue }
                stack[stack.count - 1].1 -= 1
                let parent = stack[stack.count - 1].0
                let (d, n) = node(parent)
                parent.dirs.append(d)
                if n > 0 { stack.append((d, n)) }
            }
            guard !r.bad, r.atEnd else { NSLog("Rumi: saved scan is damaged, ignoring it"); return nil }
            return Loaded(top: top, scannedAt: scannedAt, big: big, cats: cats, denied: denied, kinds: kinds, baselineAt: baselineAt, baseUsed: baseUsed)
        }
    }

    static func loadDupes() -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: dupesURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["version"] as? Int == 1 else { return nil }
        if let memo = obj["memo"] as? [String: [String]] { HashMemo.shared.load(memo) }
        return obj["groups"] as? [[String: Any]]
    }

    // MARK: byte helpers

    struct Writer {
        var data = Data(capacity: 8 << 20)
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
        mutating func f64(_ v: Double) { u64(v.bitPattern) }
        mutating func str(_ s: String) { var s = s; s.withUTF8 { b in u32(UInt32(b.count)); data.append(contentsOf: b) } }
    }

    struct Reader {
        let p: UnsafeRawBufferPointer
        var i = 0
        var bad = false
        init(_ p: UnsafeRawBufferPointer) { self.p = p }
        var atEnd: Bool { i == p.count }
        var left: Int { p.count - i }
        private mutating func take(_ n: Int) -> Int? {
            guard !bad, n >= 0, i + n <= p.count else { bad = true; return nil }
            defer { i += n }
            return i
        }
        mutating func u8() -> UInt8 { guard let o = take(1) else { return 0 }; return p[o] }
        mutating func u32() -> UInt32 { guard let o = take(4) else { return 0 }; return UInt32(littleEndian: p.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
        mutating func u64() -> UInt64 { guard let o = take(8) else { return 0 }; return UInt64(littleEndian: p.loadUnaligned(fromByteOffset: o, as: UInt64.self)) }
        mutating func i64() -> Int64 { Int64(bitPattern: u64()) }
        mutating func f64() -> Double { Double(bitPattern: u64()) }
        mutating func str() -> String {
            let n = Int(u32())
            guard n < 1 << 20, let o = take(n) else { bad = true; return "" }
            return String(decoding: UnsafeRawBufferPointer(rebasing: p[o..<o + n]), as: UTF8.self)
        }
    }
}

/// File fingerprints from earlier duplicate checks, keyed by path + size + modified time, so unchanged files aren't re-read.
final class HashMemo {
    static let shared = HashMemo()
    private let lock = NSLock()
    private var partial: [String: String] = [:], full: [String: String] = [:]
    private var used = Set<String>()

    static func key(_ path: String, _ bytes: Int64, _ mtime: Double) -> String { "\(bytes)|\(mtime)|\(path)" }

    func cached(_ k: String, full wantFull: Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        let v = wantFull ? full[k] : partial[k]
        if v != nil { used.insert(k) }
        return v
    }
    func store(_ k: String, _ h: String, full isFull: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isFull { full[k] = h } else { partial[k] = h }
        used.insert(k)
    }
    /// Start of a duplicate run: forget which fingerprints were used, so the saved memo only keeps live files.
    func beginRun() { lock.lock(); used.removeAll(); lock.unlock() }
    func export() -> [String: [String]] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: [String]] = [:]
        for k in used { out[k] = [partial[k] ?? "", full[k] ?? ""] }
        return out
    }
    func load(_ m: [String: [String]]) {
        lock.lock(); defer { lock.unlock() }
        for (k, v) in m where v.count == 2 {
            if !v[0].isEmpty { partial[k] = v[0] }
            if !v[1].isEmpty { full[k] = v[1] }
        }
    }
}
