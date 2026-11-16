// Rumi — the scan model and the parallel disk scanner.
import Foundation
import Darwin

let HOME = NSHomeDirectory()
let KEEP_FILE_MIN: Int64 = 512 * 1024      // files smaller than this are rolled up per folder
let DUP_MIN: Int64 = 1024 * 1024           // duplicates: only files >= 1 MB
let CHILD_LIMIT = 80                       // max children sent per node to the page
let SF_DATALESS_FLAG: UInt32 = 0x40000000  // iCloud / File Provider placeholder: reading it downloads it

let CATS = ["video", "image", "audio", "docs", "archive", "dev", "app", "cache", "other"]
let CAT_VIDEO = 0, CAT_IMAGE = 1, CAT_DEV = 5, CAT_APP = 6, CAT_CACHE = 7, CAT_OTHER = 8

let EXT: [String: Int] = {
    var m: [String: Int] = [:]
    let table: [(Int, String)] = [
        (0, "mp4 mov m4v mkv avi webm wmv flv mpg mpeg prores mxf braw r3d"),
        (1, "jpg jpeg png gif heic heif webp tif tiff psd ai raw cr2 cr3 nef arw dng svg bmp exr sketch fig"),
        (2, "mp3 wav aif aiff m4a flac aac ogg opus caf logicx band mid"),
        (3, "pdf doc docx xls xlsx ppt pptx key pages numbers txt md rtf csv epub odt html htm mhtml webarchive"),
        (4, "zip dmg pkg tar gz tgz bz2 xz rar 7z iso xip sparseimage sparsebundle"),
        (5, "js mjs cjs ts tsx jsx py pyc swift o a so dylib map wasm jar class rs go c h cpp node css scss json vue svelte java kt rb php sh sql toml yaml yml"),
    ]
    for (c, s) in table { for e in s.split(separator: " ") { m[String(e)] = c } }
    return m
}()
/// Kinds: finer than categories, for the header filters ("Documents → Web pages"). At most 31 so a mask fits a JS int.
struct Kind { let id: Int; let label: String; let cat: Int; let exts: [String] }
let KINDS: [Kind] = {
    let t: [(String, Int, String)] = [
        ("MP4 & MOV", 0, "mp4 mov m4v"), ("Other video", 0, "mkv avi webm wmv flv mpg mpeg"), ("Pro video", 0, "prores mxf braw r3d"),
        ("JPEG", 1, "jpg jpeg"), ("PNG", 1, "png"), ("HEIC", 1, "heic heif"), ("GIF", 1, "gif"), ("RAW", 1, "raw cr2 cr3 nef arw dng"),
        ("Design files", 1, "psd ai sketch fig"), ("Other images", 1, "webp tif tiff svg bmp exr"),
        ("Music", 2, "mp3 m4a aac flac ogg opus"), ("WAV & AIFF", 2, "wav aif aiff caf"), ("Audio projects", 2, "logicx band mid"),
        ("Web pages", 3, "html htm mhtml webarchive"), ("PDF", 3, "pdf"), ("Slides", 3, "key ppt pptx"), ("Word & Pages", 3, "doc docx pages rtf odt"),
        ("Spreadsheets", 3, "xls xlsx numbers csv"), ("Text & Markdown", 3, "txt md"), ("Books", 3, "epub"),
        ("Zip", 4, "zip"), ("Disk images", 4, "dmg iso sparseimage sparsebundle"), ("Installers", 4, "pkg xip"), ("Other archives", 4, "tar gz tgz bz2 xz rar 7z"),
        ("JavaScript & TypeScript", 5, "js mjs cjs ts tsx jsx"), ("Python", 5, "py pyc"), ("Swift", 5, "swift"), ("Web code", 5, "css scss json vue svelte"),
        ("Other code", 5, "rs go c h cpp java kt rb php sh sql toml yaml yml"), ("Built files", 5, "o a so dylib map wasm jar class node"),
    ]
    return t.enumerated().map { Kind(id: $0.offset, label: $0.element.0, cat: $0.element.1, exts: $0.element.2.split(separator: " ").map(String.init)) }
}()
let KIND_OF: [String: Int] = { var m: [String: Int] = [:]; for k in KINDS { for e in k.exts { m[e] = k.id } }; return m }()

let DEV_DIRS: Set<String> = ["node_modules", ".git", "DerivedData", ".venv", "venv", "__pycache__", ".next",
                             ".gradle", ".cargo", ".rustup", "Pods", ".npm", ".pnpm-store", ".yarn", "site-packages"]
let CACHE_DIRS: Set<String> = ["Caches", ".cache", "Cache", "CachedData", "GPUCache", "Code Cache", "ShaderCache"]
let PKG_SUFFIXES = [".app", ".photoslibrary", ".bundle", ".framework", ".fcpbundle"]

func dirContext(_ name: String, _ parent: Int?) -> Int? {
    if let p = parent { return p }
    if name.hasSuffix(".app") { return CAT_APP }
    if DEV_DIRS.contains(name) { return CAT_DEV }
    if CACHE_DIRS.contains(name) { return CAT_CACHE }
    if name.hasSuffix(".photoslibrary") || name.hasSuffix(".photolibrary") { return CAT_IMAGE }
    if name.hasSuffix(".fcpbundle") || name.hasSuffix(".imovielibrary") { return CAT_VIDEO }
    return nil
}

/// A file name's extension, lowercased ("" when it has none; a leading dot doesn't count).
func fileExt(_ name: String) -> String {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
    return name[name.index(after: dot)...].lowercased()
}

func fileCat(_ name: String, _ ctx: Int?) -> Int { ctx ?? EXT[fileExt(name)] ?? CAT_OTHER }

/// A directory entry's name.
func direntName(_ ent: UnsafeMutablePointer<dirent>) -> String {
    withUnsafePointer(to: &ent.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
    }
}

/// `was`: its size in the scan Rumi compares against ("since last time"); -1 if it wasn't there (or was under 512 KB).
struct FileRec { var name: String; var alloc: Int64; var bytes: Int64; var mtime: Double; var cat: Int; var was: Int64 = -1 }
/// Something that was in the folder at the comparison scan and isn't now.
struct Gone { var name: String; var size: Int64; var dir: Bool; var cat: Int }
struct BigFile { var path: String; var alloc: Int64; var bytes: Int64; var mtime: Double; var cat: Int; var user: Bool }

final class Dir {
    var name: String
    weak var parent: Dir?
    var size: Int64 = 0
    var count = 0
    var dirs: [Dir] = []
    var files: [FileRec] = []
    var small: Int64 = 0
    var smallN = 0
    var cat = CAT_OTHER
    var mtime: Double = 0
    var denied = false
    var pkg = false
    var kinds: UInt32 = 0   // which KINDS are anywhere inside (only files outside app/dev/cache contexts)
    // "since last time" (Changes.swift): this folder's size and small-file total in the comparison scan (-1: it wasn't
    // there), what has gone from it since, and how much moved anywhere inside it (grown + shrunk + new + gone)
    /// What's inside by category, for the stripe on a folder's label: nine shares of 0–127, seven bits each (0: not known).
    var mix: UInt64 = 0
    var was: Int64 = -1
    var wasSmall: Int64 = 0
    var gone: [Gone] = []
    var churn: Int64 = 0
    var catv: [Int64]? = [Int64](repeating: 0, count: 9)   // only while scanning

    init(name: String, parent: Dir?) {
        self.name = name
        self.parent = parent
        pkg = PKG_SUFFIXES.contains { name.hasSuffix($0) }
    }

    /// Absolute path; roots carry their absolute path as their name, "This Mac" has "".
    var path: String {
        var parts: [String] = []
        var n: Dir? = self
        while let m = n, m.parent != nil {
            if m.name.hasPrefix("/") { parts.append(m.name); break }
            parts.append(m.name)
            n = m.parent
        }
        return parts.reversed().joined(separator: "/")
    }

    func addFile(_ name: String, _ st: stat, ctx: Int?, fullPath: () -> String, big: inout [BigFile], kt: inout [Int64]) {
        let alloc = Int64(st.st_blocks) * 512
        let ext = fileExt(name)
        let c = ctx ?? (EXT[ext] ?? CAT_OTHER)
        if ctx == nil, let k = KIND_OF[ext] { kinds |= 1 << UInt32(k); kt[k * 2] += 1; kt[k * 2 + 1] += alloc }
        catv?[c] += alloc
        size += alloc
        count += 1
        let mt = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        if mt > mtime { mtime = mt }
        if alloc >= KEEP_FILE_MIN {
            files.append(FileRec(name: name, alloc: alloc, bytes: Int64(st.st_size), mtime: mt, cat: c))
            if alloc >= DUP_MIN { big.append(BigFile(path: fullPath(), alloc: alloc, bytes: Int64(st.st_size), mtime: mt, cat: c, user: ctx == nil)) }
        } else {
            small += alloc
            smallN += 1
        }
    }

    /// Settle category and newest-change time (children already rolled in; the breakdown stays for the parent).
    func finish() {
        if let v = catv, let mx = v.max(), mx > 0, let i = v.firstIndex(of: mx) {
            cat = i
            let total = Double(v.reduce(0, +))
            var m: UInt64 = 0
            for (j, x) in v.enumerated() where x > 0 { m |= UInt64(max(1, (Double(x) / total * 127).rounded())) << UInt64(j * 7) }
            mix = m
        } else { cat = CAT_OTHER }
        for ch in dirs where ch.mtime > mtime { mtime = ch.mtime }
    }

    /// Add this (already settled) folder's totals to a parent.
    func roll(into p: Dir) {
        p.size += size
        p.count += count
        p.kinds |= kinds
        if let v = catv, p.catv != nil { for i in 0..<9 { p.catv![i] += v[i] } }
    }
}

/// A shared stack of folders to list. pop() blocks until there is work or everything is done.
final class WorkQueue {
    private var items: [Store.Work] = []
    private var pending = 0
    private let cond = NSCondition()
    let resultLock = NSLock()
    func push(_ w: Store.Work) { cond.lock(); items.append(w); pending += 1; cond.signal(); cond.unlock() }
    func pop() -> Store.Work? {
        cond.lock(); defer { cond.unlock() }
        while items.isEmpty { if pending == 0 { return nil }; cond.wait() }
        return items.removeLast()
    }
    func finished() { cond.lock(); pending -= 1; if pending == 0 { cond.broadcast() }; cond.unlock() }
}

struct DupState {
    var status = "idle"
    var groups: [[String: Any]] = []   // the last finished result stays visible while a new check runs
    var rev = 0                        // bumps whenever groups are replaced
    var progress = 0
    var total = 0
}

final class Store {
    static let shared = Store()
    let lock = NSLock()            // guards the tree, index, bigFiles, dupes
    let progressLock = NSLock()    // guards filesSeen / current

    var root: Dir?
    var roots: [String] = [HOME, "/Applications"]
    var index: [String: Dir] = [:]
    var bigFiles: [BigFile] = []
    var catTotals = [Int64](repeating: 0, count: 9)
    var kindTotals = [Int64](repeating: 0, count: KINDS.count * 2)   // [count, bytes] per kind
    var denied: [String] = []
    var dupes = DupState()

    var scanning = false
    var filesSeen = 0
    var current = ""
    var started: Double = 0
    var finished: Double = 0
    var generation = 0
    /// True while the saved map from last time is being read (at launch, or back in after it was let go).
    var loading = false
    /// The map was let go to save memory while Rumi sits in the menu bar; the saved file has it. See unload().
    var unloaded = false
    /// The map on screen came from the saved file and hasn't been refreshed yet this launch.
    var fromSaved = false
    /// Paths the Clean up list currently suggests (Move to Trash allows these even inside an app's data).
    var suggested = Set<String>()
    /// "needed" until Full Disk Access is granted or skipped.
    var access = "needed"
    /// When the scan the map is compared against was made (0: nothing to compare with yet), and the disk's used space
    /// then (-1: not known). Guarded by `lock`.
    var baselineAt: Double = 0
    var baseUsed: Int64 = -1
    /// A trash edited the tree, so the folders' `churn` needs adding up again before it's read. Guarded by `lock`.
    var churnStale = false
    /// What was trashed while a scan runs (replayed on the new tree) and while a duplicate check runs
    /// (left out of its groups). Guarded by `lock`.
    private var scanTrash = TrashLog()
    var dupesTrash = TrashLog()

    private var seenLinks = Set<UInt64>()
    private let linkLock = NSLock()

    // MARK: scanning

    /// With a saved map on screen, the launch rescan is "background": it waits for the window to settle and runs at
    /// low priority so the map stays snappy. A Rescan the user asks for runs at full speed.
    /// The page's viewer is open (a quiet rescan waits for it to close).
    var viewerOpen = false

    func startScan(quiet: Bool = false) {
        lock.lock()
        if scanning { lock.unlock(); return }
        scanning = true
        generation += 1
        let gen = generation
        let background = quiet && (root != nil || loading || unloaded)
        lock.unlock()
        progressLock.lock(); filesSeen = 0; current = ""; progressLock.unlock()
        started = Date().timeIntervalSince1970
        let t = Thread { [self] in
            while loading { Thread.sleep(forTimeInterval: 0.05) }
            if background && root != nil { Thread.sleep(forTimeInterval: 2.5); started = Date().timeIntervalSince1970 }
            runScan(gen: gen, background: background)
        }
        t.stackSize = 64 << 20
        t.qualityOfService = background ? .utility : .userInitiated
        t.start()
    }

    private func progress(_ n: Int, _ path: String) {
        progressLock.lock()
        filesSeen += n
        current = path
        progressLock.unlock()
    }

    private func runScan(gen: Int, background: Bool = false) {
        linkLock.lock(); seenLinks.removeAll(); linkLock.unlock()
        let top = Dir(name: "This Mac", parent: nil)
        let queue = WorkQueue()
        for r in roots {
            var st = stat()
            guard lstat(r, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
            let node = Dir(name: r, parent: top)
            top.dirs.append(node)
            queue.push(Work(dir: node, path: r, ctx: dirContext((r as NSString).lastPathComponent, nil), dev: st.st_dev))
        }
        // Every folder is its own job: workers list a folder, keep its files, and queue its subfolders.
        // the quiet launch rescan leaves room for the person using the app: two workers, and a pause while the viewer is open
        let workers = background ? 2 : max(4, ProcessInfo.processInfo.activeProcessorCount)
        var bigs = [[BigFile]](repeating: [], count: workers)
        var denieds = [[String]](repeating: [], count: workers)
        var kts = [[Int64]](repeating: [], count: workers)
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            var big: [BigFile] = [], denied: [String] = [], local = 0, kt = [Int64](repeating: 0, count: KINDS.count * 2)
            while let job = queue.pop() {
                while background && viewerOpen { usleep(50_000) }
                list(job, queue: queue, big: &big, denied: &denied, local: &local, kt: &kt)
                queue.finished()
            }
            progress(local & 4095, "")
            queue.resultLock.lock(); bigs[w] = big; denieds[w] = denied; kts[w] = kt; queue.resultLock.unlock()
        }

        // Roll sizes up: children before parents (reverse of a pre-order walk).
        var order: [Dir] = []
        order.reserveCapacity(150_000)
        var stack = [top]
        while let d = stack.popLast() { order.append(d); stack.append(contentsOf: d.dirs) }
        for d in order.reversed() {
            for c in d.dirs { c.roll(into: d) }
            d.finish()   // parents still need this folder's breakdown
            for c in d.dirs { c.catv = nil }
        }
        let totals = top.catv ?? [Int64](repeating: 0, count: 9)
        top.catv = nil
        let idx = Store.buildIndex(top)
        let big = bigs.flatMap { $0 }.sorted { $0.alloc > $1.alloc }, den = denieds.flatMap { $0 }   // biggest first, kept that way
        var kinds = [Int64](repeating: 0, count: KINDS.count * 2)
        for kt in kts where kt.count == kinds.count { for i in kinds.indices { kinds[i] += kt[i] } }
        let now = Date().timeIntervalSince1970
        // the tree isn't shared yet, so it can be compared and encoded without holding the lock
        let base = Changes.compare(top, roots: roots, now: now)   // marks what grew, shrank, is new or gone since last time
        let saved = Snapshot.encode(top: top, roots: roots, scannedAt: now, files: top.count, big: big, cats: totals, denied: den, kinds: kinds,
                                    baselineAt: base.at, baseUsed: base.used)
        History.record(at: now, top: top)

        lock.lock()
        // the old map moves into locals and is freed after the unlock, not while the page waits on the lock
        let old = (root, index, bigFiles)
        root = top
        index = idx
        bigFiles = big
        catTotals = totals
        kindTotals = kinds
        denied = den
        baselineAt = base.at; baseUsed = base.used; churnStale = false
        let edited = replayTrash()   // things trashed while this scan ran may still be in the new tree
        dupes.status = "running"   // the duplicate check starts right below; unload() waits for it
        scanning = false
        fromSaved = false
        unloaded = false
        finished = now
        lock.unlock()
        withExtendedLifetime(old) {}
        linkLock.lock(); seenLinks = []; linkLock.unlock()   // only needed while scanning (it can hold hundreds of thousands of entries)
        // a replayed trash changed the tree after it was encoded: save the edited one instead
        if edited { Snapshot.saveSoon() } else { Snapshot.write(saved) }
        NSLog("Rumi: scanned \(filesSeen) files in \(String(format: "%.1f", finished - started)) s")
        DispatchQueue.global(qos: .utility).async { findDuplicates(gen: gen) }
        Hidden.measure()   // the system side changes too; measure it fresh for the "macOS keeps this" card
    }

    static func buildIndex(_ top: Dir) -> [String: Dir] {
        var idx: [String: Dir] = [:]
        idx.reserveCapacity(150_000)
        var walk: [(Dir, String)] = top.dirs.map { ($0, $0.name) }
        while let (d, p) = walk.popLast() {
            idx[p] = d
            for c in d.dirs { walk.append((c, p + "/" + c.name)) }
        }
        return idx
    }

    /// Show last launch's map right away. Call before startScan; the scan then refreshes it quietly.
    func loadSaved() {
        let t0 = Date()
        let saved = Snapshot.load(roots: roots)
        if let s = saved, s.baselineAt > 0 { Changes.addUp(s.top) }
        let groups = saved == nil ? nil : Snapshot.loadDupes()
        let idx = saved.map { Store.buildIndex($0.top) }
        let big = saved?.big.sorted { $0.alloc > $1.alloc } ?? []
        lock.lock()
        loading = false
        if let s = saved, let idx = idx, root == nil {
            root = s.top; index = idx; bigFiles = big; catTotals = s.cats; denied = s.denied; if s.kinds.count == kindTotals.count { kindTotals = s.kinds }
            finished = s.scannedAt
            baselineAt = s.baselineAt; baseUsed = s.baseUsed
            fromSaved = true
            if let g = groups { dupes.groups = g; dupes.status = "done"; dupes.rev += 1 }
        }
        lock.unlock()
        if saved != nil { NSLog("Rumi: opened the saved map in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms") }
    }

    /// Let the map go: with the window closed and search not in use, Rumi doesn't need 174,000 folders in memory. The saved
    /// file has them and reads back in about half a second (ensureLoaded). Not while a scan or a duplicate check runs.
    @discardableResult func unload() -> Bool {
        lock.lock()
        guard root != nil, !scanning, !loading, dupes.status != "running" else { lock.unlock(); return false }
        let old = (root, index, bigFiles, dupes.groups)
        root = nil; index = [:]; bigFiles = []; dupes.groups = []; dupes.status = "idle"; suggested = []
        unloaded = true
        lock.unlock()
        withExtendedLifetime(old) {}
        DispatchQueue.global(qos: .utility).async { malloc_zone_pressure_relief(nil, 0) }   // hand the freed pages back now
        return true
    }

    /// Read the map back in if it was let go. Returns at once; the status says "loading" until it's there. A scan that's
    /// running doesn't stop this: the saved map shows until the new one lands (loadSaved never replaces a newer map).
    func ensureLoaded() {
        lock.lock()
        guard root == nil, unloaded, !loading else { lock.unlock(); return }
        loading = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            loadSaved()
            lock.lock(); let none = root == nil; if !none { unloaded = false }; lock.unlock()
            if none, access != "needed" { startScan() }   // the saved file is gone or unreadable: scan
        }
    }

    struct Work { let dir: Dir; let path: String; let ctx: Int?; let dev: dev_t }

    /// List one folder: files are kept on the folder, subfolders become new jobs.
    private func list(_ job: Work, queue: WorkQueue, big: inout [BigFile], denied: inout [String], local: inout Int, kt: inout [Int64]) {
        let d = job.dir
        guard let dp = opendir(job.path) else { d.denied = true; denied.append(job.path); return }
        defer { closedir(dp) }
        let fd = dirfd(dp)
        while let ent = readdir(dp) {
            let name = direntName(ent)
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let mode = st.st_mode & S_IFMT
            if mode == S_IFLNK { continue }
            if mode == S_IFDIR {
                if st.st_dev != job.dev { continue }   // another volume
                let child = Dir(name: name, parent: d)
                d.dirs.append(child)
                // cloud placeholder folders are listed but never opened (opening downloads them)
                if st.st_flags & SF_DATALESS_FLAG == 0 {
                    queue.push(Work(dir: child, path: job.path + "/" + name, ctx: dirContext(name, job.ctx), dev: job.dev))
                }
                continue
            }
            guard notDuplicateLink(st) else { continue }
            d.addFile(name, st, ctx: job.ctx, fullPath: { job.path + "/" + name }, big: &big, kt: &kt)
            local += 1
            if local & 4095 == 0 { progress(4096, job.path) }
        }
    }

    private func notDuplicateLink(_ st: stat) -> Bool {
        if st.st_nlink <= 1 { return true }
        let key = (UInt64(UInt32(bitPattern: st.st_dev)) << 40) ^ UInt64(st.st_ino)
        linkLock.lock(); defer { linkLock.unlock() }
        return seenLinks.insert(key).inserted
    }

    // MARK: edits after Move to Trash / Empty Trash

    /// Remove a trashed path from the tree and fix sizes upward. Call with `lock` held.
    /// `size`: the allocated bytes (st_blocks × 512) of a file trashed by path, read before it moved. Files under
    /// 512 KB aren't in the tree, only in their folder's `small` total, so without it the map can't shrink for them.
    func detach(_ p: String, size: Int64? = nil) {
        if scanning { scanTrash.paths.append(p) }
        if dupesTrash.on { dupesTrash.paths.append(p) }
        detachNow(p, size: size)
    }

    func emptiedTrash() {
        lock.lock(); defer { lock.unlock() }
        if scanning { scanTrash.emptied = true }
        if dupesTrash.on { dupesTrash.emptied = true }
        emptyTrashNode()
    }

    /// Returns whether the tree changed.
    @discardableResult
    private func detachNow(_ p: String, size: Int64?) -> Bool {
        let parentPath = (p as NSString).deletingLastPathComponent
        let name = (p as NSString).lastPathComponent
        guard let parent = index[parentPath] else { return false }
        let ctx = context(of: parent)
        var removed: Int64 = 0, cnt = 0
        if let i = parent.dirs.firstIndex(where: { $0.name == name }) {
            let d = parent.dirs.remove(at: i)
            removed = d.size; cnt = d.count
            if baselineAt > 0, d.was >= Changes.MIN { parent.gone.append(Gone(name: d.name, size: d.was, dir: true, cat: d.cat)) }
            forget(d, path: p, ctx: dirContext(name, ctx), keepSelf: false)
            bigFiles.removeAll { $0.path == p || $0.path.hasPrefix(p + "/") }   // removeAll keeps the biggest-first order
        } else if let i = parent.files.firstIndex(where: { $0.name == name }) {
            let f = parent.files.remove(at: i)
            removed = f.alloc; cnt = 1
            if baselineAt > 0, f.was >= 0 { parent.gone.append(Gone(name: f.name, size: f.was, dir: false, cat: f.cat)) }
            uncount(f.name, f.alloc, cat: f.cat, ctx: ctx)
            if f.alloc >= DUP_MIN { bigFiles.removeAll { $0.path == p } }
        } else if let sz = size, sz < KEEP_FILE_MIN, parent.smallN > 0 {
            // a small file: it only ever counted in its folder's rolled-up total
            removed = min(max(0, sz), parent.small); cnt = 1
            parent.small -= removed; parent.smallN -= 1
            uncount(name, removed, cat: fileCat(name, ctx), ctx: ctx)
        } else {
            return false
        }
        var n: Dir? = parent
        while let m = n { m.size -= removed; m.count -= cnt; n = m.parent }
        dupes.groups = Store.prune(dupes.groups) { $0 == p || $0.hasPrefix(p + "/") }
        churnStale = true
        return true
    }

    /// Clear the Trash folder in the tree. Call with `lock` held. Returns whether the tree changed.
    @discardableResult
    private func emptyTrashNode() -> Bool {
        let tp = HOME + "/.Trash"
        guard let tr = index[tp], tr.count > 0 || !tr.dirs.isEmpty else { return false }
        let removed = tr.size, cnt = tr.count
        forget(tr, path: tp, ctx: context(of: tr), keepSelf: true)
        if baselineAt > 0 {
            tr.gone += tr.dirs.filter { $0.was >= Changes.MIN }.map { Gone(name: $0.name, size: $0.was, dir: true, cat: $0.cat) }
            tr.gone += tr.files.filter { $0.was >= 0 }.map { Gone(name: $0.name, size: $0.was, dir: false, cat: $0.cat) }
        }
        churnStale = true
        tr.dirs = []; tr.files = []; tr.small = 0; tr.smallN = 0; tr.kinds = 0
        var n: Dir? = tr
        while let m = n { m.size -= removed; m.count -= cnt; n = m.parent }
        bigFiles.removeAll { $0.path.hasPrefix(tp + "/") }
        dupes.groups = Store.prune(dupes.groups) { $0.hasPrefix(tp + "/") }
        return true
    }

    /// Re-apply what was trashed while the scan ran: the new tree may have listed those folders first.
    /// Anything that's back on disk (put back) stays. Call with `lock` held, the new tree in place.
    private func replayTrash() -> Bool {
        defer { scanTrash = TrashLog() }
        func gone(_ p: String) -> Bool { var st = stat(); return lstat(p, &st) != 0 }
        var changed = false
        let tp = HOME + "/.Trash"
        if scanTrash.emptied, let tr = index[tp] {
            let names = tr.dirs.map(\.name) + tr.files.map(\.name)
            let left = Set(names.filter { !gone(tp + "/" + $0) })
            if left.isEmpty { changed = emptyTrashNode() }
            else { for nm in names where !left.contains(nm) { if detachNow(tp + "/" + nm, size: nil) { changed = true } } }
        }
        // small files are left alone here: the new scan may or may not have counted them
        for p in scanTrash.paths where gone(p) { if detachNow(p, size: nil) { changed = true } }
        if changed { NSLog("Rumi: re-applied trash made during the scan") }
        return changed
    }

    /// The category a folder's files take from an enclosing app, developer or cache folder (nil: by extension).
    private func context(of d: Dir) -> Int? {
        var chain: [Dir] = []
        var n: Dir? = d
        while let m = n, m.parent != nil {
            chain.append(m)
            if m.name.hasPrefix("/") { break }
            n = m.parent
        }
        var ctx: Int?
        for m in chain.reversed() { ctx = dirContext(m.name.hasPrefix("/") ? (m.name as NSString).lastPathComponent : m.name, ctx) }
        return ctx
    }

    /// Take a removed folder's contents out of the index and the category and kind totals.
    /// Files of 512 KB and up count exactly. Smaller files are only a per-folder total: inside an app, developer or
    /// cache folder they take that category (exact); elsewhere they're charged to their folder's main category, and
    /// their kinds can't be told apart, so kind totals only lose the files the map keeps.
    private func forget(_ d: Dir, path: String, ctx: Int?, keepSelf: Bool) {
        var stack: [(Dir, String, Int?)] = [(d, path, ctx)]
        while let (x, p, c) = stack.popLast() {
            if !(keepSelf && x === d) { index.removeValue(forKey: p) }
            for f in x.files { uncount(f.name, f.alloc, cat: f.cat, ctx: c) }
            if x.small > 0 { let sc = c ?? x.cat; catTotals[sc] = max(0, catTotals[sc] - x.small) }
            for ch in x.dirs { stack.append((ch, p + "/" + ch.name, dirContext(ch.name, c))) }
        }
    }

    /// One file leaves the category totals, and the kind totals if it counted there (outside app/dev/cache folders).
    private func uncount(_ name: String, _ alloc: Int64, cat: Int, ctx: Int?) {
        catTotals[cat] = max(0, catTotals[cat] - alloc)
        if ctx == nil, let k = KIND_OF[fileExt(name)], kindTotals.count > k * 2 + 1 {
            kindTotals[k * 2] = max(0, kindTotals[k * 2] - 1)
            kindTotals[k * 2 + 1] = max(0, kindTotals[k * 2 + 1] - alloc)
        }
    }

    /// Drop files from duplicate groups. Groups left with fewer than two files go; the rest recount their waste.
    static func prune(_ groups: [[String: Any]], dropping gone: (String) -> Bool) -> [[String: Any]] {
        groups.compactMap { g in
            let all = g["files"] as? [[String: Any]] ?? []
            let files = all.filter { !gone($0["path"] as? String ?? "") }
            if files.count == all.count { return g }
            guard files.count > 1 else { return nil }
            var g = g
            g["files"] = files
            g["waste"] = dupeWaste(files)
            if g["clones"] != nil { g["clones"] = cloneShared(files) }
            return g
        }
    }

    /// What trashing every copy but one frees. Copies that are APFS clones of each other share their blocks
    /// (same "clone" family), so only the first of each family counts.
    static func dupeWaste(_ files: [[String: Any]]) -> Int64 {
        var families = Set<String>(), w: Int64 = 0
        for (i, f) in files.enumerated() {
            if let c = f["clone"] as? String, !families.insert(c).inserted { continue }
            if i > 0 { w += (f["size"] as? NSNumber)?.int64Value ?? 0 }
        }
        return w
    }

    /// Two or more of these files are clones of each other.
    static func cloneShared(_ files: [[String: Any]]) -> Bool {
        let ids = files.compactMap { $0["clone"] as? String }
        return Set(ids).count < ids.count
    }
}

/// Paths trashed while a long job ran on its own copy of the map.
struct TrashLog {
    var on = false
    var paths: [String] = []
    var emptied = false
    func covers(_ p: String) -> Bool {
        (emptied && p.hasPrefix(HOME + "/.Trash/")) || paths.contains { p == $0 || p.hasPrefix($0 + "/") }
    }
}
