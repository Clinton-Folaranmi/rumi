// Rumi — `Rumi --bench-private [folder]`: the speed test for "real sizes" (roadmap item 05).
// Walks a folder three ways with the same number of workers and prints how long each takes:
//   A  readdir + fstatat          what the scanner does today (allocated size)
//   B  getattrlistbulk            the same facts, asked for a whole folder at a time
//   C  getattrlistbulk + private  B plus ATTR_CMNEXT_PRIVATESIZE: the bytes that would be freed if the file were deleted
// The question it answers: can the scanner ask for private size on every file without slowing the scan?
// Result (Nov 2026, 1.3 million files): C took 1.8 times as long as A, so private size is read only for the things about
// to be removed, never for the whole map. B was 28% faster than A.
import Foundation
import Darwin

enum PrivateBench {
    struct Totals { var files = 0, dirs = 0; var alloc: Int64 = 0, priv: Int64 = 0, denied = 0 }

    /// A shared stack of folders; `each` lists one folder and returns its subfolders.
    private static func walk(_ root: String, workers: Int, each: @escaping (String, inout Totals) -> [String]) -> Totals {
        let cond = NSCondition()
        var stack = [root], pending = 1, total = Totals()
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            var mine = Totals()
            while true {
                cond.lock()
                while stack.isEmpty && pending > 0 { cond.wait() }
                guard let p = stack.popLast() else { cond.unlock(); break }
                cond.unlock()
                let subs = each(p, &mine)
                cond.lock()
                stack.append(contentsOf: subs); pending += subs.count - 1
                if pending == 0 || !subs.isEmpty { cond.broadcast() }
                cond.unlock()
            }
            cond.lock()
            total.files += mine.files; total.dirs += mine.dirs; total.alloc += mine.alloc; total.priv += mine.priv; total.denied += mine.denied
            cond.unlock()
        }
        return total
    }

    /// A: what Store.list does.
    private static func viaStat(_ path: String, _ t: inout Totals) -> [String] {
        guard let dp = opendir(path) else { t.denied += 1; return [] }
        defer { closedir(dp) }
        let fd = dirfd(dp)
        var subs: [String] = []
        while let ent = readdir(dp) {
            let name = direntName(ent)
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let mode = st.st_mode & S_IFMT
            if mode == S_IFLNK { continue }
            if mode == S_IFDIR { t.dirs += 1; if st.st_flags & SF_DATALESS_FLAG == 0 { subs.append(path + "/" + name) }; continue }
            t.files += 1; t.alloc += Int64(st.st_blocks) * 512
        }
        return subs
    }

    /// B and C: one call returns many entries. With FSOPT_PACK_INVAL_ATTRS every entry has the same layout:
    /// u32 length · attribute_set_t (20) · name reference (8) · object type (4) · flags (4) · allocated size (8) [· private size (8)]
    private static func viaBulk(_ path: String, _ t: inout Totals, withPrivate: Bool) -> [String] {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { t.denied += 1; return [] }
        defer { close(fd) }
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FLAGS)
        al.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
        if withPrivate { al.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) }
        let opts = UInt64(FSOPT_PACK_INVAL_ATTRS) | (withPrivate ? UInt64(FSOPT_ATTR_CMN_EXTENDED) : 0)
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
                if type == 2 {   // VDIR
                    t.dirs += 1
                    if flags & SF_DATALESS_FLAG == 0 {
                        let off = Int(p.loadUnaligned(fromByteOffset: 24, as: Int32.self))
                        subs.append(path + "/" + String(cString: (p + 24 + off).assumingMemoryBound(to: CChar.self)))
                    }
                } else if type == 1 {   // VREG
                    t.files += 1
                    t.alloc += p.loadUnaligned(fromByteOffset: 40, as: Int64.self)
                    if withPrivate { t.priv += p.loadUnaligned(fromByteOffset: 48, as: Int64.self) }
                }
                p += len
            }
        }
        return subs
    }

    static func run(_ root: String) {
        let workers = max(4, ProcessInfo.processInfo.activeProcessorCount)
        func pass(_ label: String, _ each: @escaping (String, inout Totals) -> [String]) -> Double {
            let t0 = Date(), t = walk(root, workers: workers, each: each), secs = Date().timeIntervalSince(t0)
            print(String(format: "%@  %6.1f s · %d files · %d folders · %.1f GB allocated%@ · %d unreadable", label, secs, t.files, t.dirs, Double(t.alloc) / 1e9,
                         t.priv > 0 ? String(format: " · %.1f GB private", Double(t.priv) / 1e9) : "", t.denied))
            return secs
        }
        print("folder: \(root) · \(workers) workers · \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "Low Power Mode ON" : "Low Power Mode off")")
        _ = pass("warm-up (A)            ", viaStat)
        var a: [Double] = [], b: [Double] = [], c: [Double] = []
        for _ in 0..<2 {
            a.append(pass("A readdir + fstatat    ", viaStat))
            b.append(pass("B getattrlistbulk      ", { viaBulk($0, &$1, withPrivate: false) }))
            c.append(pass("C bulk + private size  ", { viaBulk($0, &$1, withPrivate: true) }))
        }
        let A = a.min()!, B = b.min()!, C = c.min()!
        print(String(format: "best of two: A %.1f s · B %.1f s (%.2f× A) · C %.1f s (%.2f× A, %.2f× B)", A, B, B / A, C, C / A, C / B))
    }
}
