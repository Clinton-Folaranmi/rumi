// Rumi — every disk on one shelf (v2.0).
// The map shows one disk at a time: this Mac (Home and Applications, as always) or a drive that's plugged in (all of
// it). Each disk keeps its own saved map, comparison scan, history and place in the file-system log, in its own folder,
// so coming back to a drive is as quick as coming back to the Mac.
import AppKit

struct Disk { let id: String; let name: String; let path: String; let total: Int64; let free: Int64; let mac: Bool }

enum Disks {
    static let MAC = "mac"
    /// The disk the map is showing. Rumi always starts on the Mac.
    private(set) static var current = Disk(id: MAC, name: "This Mac", path: "/", total: 0, free: 0, mac: true)

    /// This Mac first, then every drive that's plugged in: local, writable and shown in Finder. Installer images and
    /// other read-only volumes aren't disks anyone tidies, and network shares are too slow to map.
    static func list() -> [Disk] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
                                      .volumeIsReadOnlyKey, .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeUUIDStringKey]
        var out: [Disk] = []
        for u in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), let total = v.volumeTotalCapacity, total > 0 else { continue }
            var free = v.volumeAvailableCapacityForImportantUsage ?? 0
            if free <= 0 { free = Int64(v.volumeAvailableCapacity ?? 0) }
            if u.path == "/" { out.insert(Disk(id: MAC, name: "This Mac", path: "/", total: Int64(total), free: free, mac: true), at: 0); continue }
            guard v.volumeIsLocal == true, v.volumeIsReadOnly != true, v.volumeIsBrowsable != false else { continue }
            let name = v.volumeName ?? u.lastPathComponent
            out.append(Disk(id: v.volumeUUIDString ?? name, name: name, path: u.path, total: Int64(total), free: free, mac: false))
        }
        return out
    }

    static func json() -> [[String: Any]] {
        list().map { ["id": $0.id, "name": $0.name, "total": $0.total, "free": $0.free, "mac": $0.mac, "on": $0.id == current.id] }
    }

    /// Where a disk's saved map and the files beside it live.
    private static func folder(for d: Disk) -> URL {
        guard !d.mac else { return Snapshot.base }
        let safe = d.id.replacingOccurrences(of: "/", with: "-")
        let u = Snapshot.base.appendingPathComponent("disks/" + safe, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Show another disk. The map of the one on screen is saved and let go; the other's saved map is read back and
    /// brought up to date, or the disk is scanned if Rumi hasn't seen it before. Returns false if it isn't there.
    @discardableResult static func use(_ id: String) -> Bool {
        guard id != current.id else { return true }
        guard let d = list().first(where: { $0.id == id }) else { return false }
        let S = Store.shared
        Live.stop()   // before the lock: an update under way finishes first
        S.lock.lock()
        if S.liveDirty, S.root != nil, !S.scanning { Snapshot.saveNow(S) }
        S.lock.unlock()
        Snapshot.writeQ.sync {}   // everything on its way to the old disk's folder lands there first
        S.lock.lock()
        let old = S.forget(roots: d.mac ? [HOME, "/Applications"] : [d.path])
        current = d
        Snapshot.dir = folder(for: d)
        S.loading = FileManager.default.fileExists(atPath: Snapshot.treeURL.path)
        S.lock.unlock()
        withExtendedLifetime(old) {}
        rootsChanged(); Frees.reset()
        DispatchQueue.global(qos: .userInitiated).async { S.loadSaved(); Live.bringCurrent() }
        return true
    }

    /// A drive was plugged in, taken out or renamed: the page redraws its shelf. If the one on screen went, Rumi goes
    /// back to the Mac first. (macOS can still list a drive for a moment after it says it's gone, so the drive the
    /// notice names counts, and so does its folder no longer being there.)
    static func watch(_ changed: @escaping (_ lostCurrent: Bool) -> Void) {
        onChange = changed
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { note in
                let named = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
                if n == NSWorkspace.didUnmountNotification, named == current.path, !current.mac { return leave() }
                if !leaveIfGone() { changed(false) }
            }
        }
    }
    private static var onChange: ((Bool) -> Void)?

    /// The drive on screen isn't there any more (its folder is gone, or it's no longer listed): back to the Mac.
    /// Safe to call from anywhere, any number of times. Returns whether Rumi left.
    @discardableResult static func leaveIfGone() -> Bool {
        guard !current.mac else { return false }
        var st = stat()
        if lstat(current.path, &st) == 0, list().contains(where: { $0.id == current.id }) { return false }
        if Thread.isMainThread { leave() } else { DispatchQueue.main.async { leave() } }
        return true
    }

    private static func leave() {
        guard !current.mac else { return }
        use(MAC)
        onChange?(true)
    }
}
