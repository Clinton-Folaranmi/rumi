// Rumi — "frees if deleted": how much space removing something really gives back.
// Files on a Mac can share space. A copy made in Finder is a clone that takes no room of its own, some tools link one
// file into many folders, and a local snapshot can hold on to data after it's deleted. A folder's size counts all of
// that; this counts only what comes back.
// It's read for the things about to be removed (the Clean up list and the tray), never for the whole map: asking for it
// on every file made a scan 1.8 times slower (speed test, Nov 2026).
import Foundation
import Darwin

enum Frees {
    struct Sizes { var uses: Int64 = 0; var frees: Int64 = 0 }

    /// A file with more than one name (a hard link): its space comes back only when every name is inside what's removed.
    private struct Link { var seen: UInt32; var names: UInt32; var alloc: Int64; var priv: Int64 }
    /// Clones of one file (copies made in Finder, or by a tool) share their data: it comes back only when every clone is
    /// inside what's removed.
    private struct Family { var seen: UInt32; var clones: UInt32; var alloc: Int64; var priv: Int64 }
    private struct Part { var s = Sizes(); var links: [UInt64: Link] = [:]; var clones: [UInt64: Family] = [:] }

    // MARK: answers are kept for as long as the thing's size on the map stays the same
    // (in memory, and in the data folder so the next launch doesn't measure everything again)

    private static let lock = NSLock()
    private static var kept: [String: (size: Int64, s: Sizes)]?
    private static var saving = false
    private static var url: URL { Snapshot.dir.appendingPathComponent("frees.json") }

    /// What removing this file or folder frees. `size` is its size on the map: a different size means it changed.
    static func of(_ path: String, size: Int64, workers: Int = 4) -> Sizes {
        lock.lock()
        if kept == nil { kept = load() }
        if let k = kept?[path], k.size == size { lock.unlock(); return k.s }
        lock.unlock()
        let s = measure(path, workers: workers)
        lock.lock()
        if (kept?.count ?? 0) > 800 { kept = [:] }
        kept?[path] = (size, s)
        lock.unlock()
        save()
        return s
    }

    /// Another disk is on screen: its answers are in its own folder.
    static func reset() { lock.lock(); kept = nil; lock.unlock() }

    /// These went to the Trash: forget them, and whatever holds them or was inside them.
    static func forget(_ paths: [String]) {
        lock.lock()
        if let k = kept { kept = k.filter { e in !paths.contains { e.key == $0 || e.key.hasPrefix($0 + "/") || $0.hasPrefix(e.key + "/") } } }
        lock.unlock()
        save()
    }

    private static func load() -> [String: (size: Int64, s: Sizes)] {
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: [Int64]] else { return [:] }
        return o.compactMapValues { $0.count == 3 ? (size: $0[0], s: Sizes(uses: $0[1], frees: $0[2])) : nil }
    }
    private static func save() {
        lock.lock(); let busy = saving; saving = true; lock.unlock()
        if busy { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            lock.lock(); saving = false; let k = kept ?? [:]; lock.unlock()
            if let d = try? JSONSerialization.data(withJSONObject: k.mapValues { [$0.size, $0.s.uses, $0.s.frees] }) { try? d.write(to: url, options: .atomic) }
        }
    }

    // MARK: measuring

    /// One file, or everything inside a folder. A link is never followed.
    static func measure(_ path: String, workers: Int = 4) -> Sizes {
        var st = stat()
        guard lstat(path, &st) == 0 else { return Sizes() }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return file(path)
        case S_IFDIR:
            if st.st_flags & UInt32(SF_DATALESS_FLAG) != 0 { return Sizes() }   // in iCloud only: listing it would download it
            var p = walk(path, workers: workers)
            for l in p.links.values { p.s.uses += l.alloc; if l.seen >= l.names { p.s.frees += l.priv } }   // counted once, like the map
            // every clone is in here: the shared data goes with them (at least the biggest one's worth). Otherwise only
            // what each clone has to itself.
            for f in p.clones.values { p.s.frees += f.seen >= f.clones ? max(f.alloc, f.priv) : f.priv }
            p.s.frees = min(p.s.frees, p.s.uses)
            return p.s
        default: return Sizes()
        }
    }

    /// One file: u32 length · attribute_set_t (20) · link count (4) · allocated size (8) · private size (8) · clone id (8) ·
    /// clone count (4)
    static func file(_ path: String, say: Bool = false) -> Sizes {
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        al.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        al.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { buf.deallocate() }
        let opts = UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_PACK_INVAL_ATTRS) | UInt32(FSOPT_ATTR_CMN_EXTENDED)
        guard getattrlist(path, &al, buf, 64, opts) == 0 else { return Sizes() }
        let names = buf.loadUnaligned(fromByteOffset: 24, as: UInt32.self)
        let alloc = buf.loadUnaligned(fromByteOffset: 28, as: Int64.self), priv = buf.loadUnaligned(fromByteOffset: 36, as: Int64.self)
        if say { print("names \(names) · allocated \(alloc) · private \(priv) · clone id \(buf.loadUnaligned(fromByteOffset: 44, as: UInt64.self)) · clones \(buf.loadUnaligned(fromByteOffset: 52, as: UInt32.self))") }
        return Sizes(uses: alloc, frees: names > 1 ? 0 : min(priv, alloc))   // another name elsewhere keeps the data
    }

    /// A shared stack of folders, listed by a few workers at once.
    private static func walk(_ root: String, workers: Int) -> Part {
        let cond = NSCondition()
        var stack = [root], pending = 1, total = Part()
        DispatchQueue.concurrentPerform(iterations: max(1, workers)) { _ in
            var mine = Part()
            while true {
                cond.lock()
                while stack.isEmpty && pending > 0 { cond.wait() }
                guard let p = stack.popLast() else { cond.unlock(); break }
                cond.unlock()
                let subs = list(p, &mine)
                cond.lock()
                stack.append(contentsOf: subs); pending += subs.count - 1
                if pending == 0 || !subs.isEmpty { cond.broadcast() }
                cond.unlock()
            }
            cond.lock()
            total.s.uses += mine.s.uses; total.s.frees += mine.s.frees
            for (id, l) in mine.links {
                if var t = total.links[id] { t.seen += l.seen; total.links[id] = t } else { total.links[id] = l }
            }
            for (id, f) in mine.clones {
                if var t = total.clones[id] { t.seen += f.seen; t.alloc = max(t.alloc, f.alloc); t.priv += f.priv; total.clones[id] = t } else { total.clones[id] = f }
            }
            cond.unlock()
        }
        return total
    }

    /// One folder, asked for a whole buffer of entries at a time. With FSOPT_PACK_INVAL_ATTRS every entry has one layout:
    /// u32 length · attribute_set_t (20) · name reference (8) · object type (4) · flags (4) · file id (8) · link count (4) ·
    /// allocated size (8) · private size (8) · clone id (8) · clone count (4). Returns the subfolders.
    private static func list(_ path: String, _ t: inout Part) -> [String] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
        al.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        al.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT)
        let opts = UInt64(FSOPT_PACK_INVAL_ATTRS) | UInt64(FSOPT_ATTR_CMN_EXTENDED)
        let size = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buf.deallocate() }
        var subs: [String] = []
        while true {
            let n = getattrlistbulk(fd, &al, buf, size, opts)
            if n <= 0 { break }
            var p = buf
            for _ in 0..<n {
                let len = Int(p.loadUnaligned(as: UInt32.self))
                let type = p.loadUnaligned(fromByteOffset: 32, as: UInt32.self), flags = p.loadUnaligned(fromByteOffset: 36, as: UInt32.self)
                if type == 2 {   // a folder
                    if flags & UInt32(SF_DATALESS_FLAG) == 0 {
                        let off = Int(p.loadUnaligned(fromByteOffset: 24, as: Int32.self))
                        subs.append(path + "/" + String(cString: (p + 24 + off).assumingMemoryBound(to: CChar.self)))
                    }
                } else if type == 1 {   // a file
                    let names = p.loadUnaligned(fromByteOffset: 48, as: UInt32.self)
                    let alloc = p.loadUnaligned(fromByteOffset: 52, as: Int64.self)
                    let priv = min(p.loadUnaligned(fromByteOffset: 60, as: Int64.self), alloc)
                    if names > 1 {
                        let id = p.loadUnaligned(fromByteOffset: 40, as: UInt64.self)
                        if var l = t.links[id] { l.seen += 1; t.links[id] = l }
                        else { t.links[id] = Link(seen: 1, names: names, alloc: alloc, priv: priv) }
                    } else {
                        t.s.uses += alloc
                        let clones = p.loadUnaligned(fromByteOffset: 76, as: UInt32.self)
                        if clones > 1 {
                            let id = p.loadUnaligned(fromByteOffset: 68, as: UInt64.self)
                            if var f = t.clones[id] { f.seen += 1; f.alloc = max(f.alloc, alloc); f.priv += priv; t.clones[id] = f }
                            else { t.clones[id] = Family(seen: 1, clones: clones, alloc: alloc, priv: priv) }
                        } else { t.s.frees += priv }
                    }
                }
                p += len
            }
        }
        return subs
    }
}
