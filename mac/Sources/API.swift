// Rumi — the JSON API the page already speaks, plus duplicates and trash.
import AppKit
import CryptoKit

private let thousands: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US"); return f
}()
func commas(_ n: Int) -> String { thousands.string(from: NSNumber(value: n)) ?? String(n) }

func diskInfo() -> [String: Any] {
    let v = try? URL(fileURLWithPath: Disks.current.path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
    let total = Int64(v?.volumeTotalCapacity ?? 0)
    // "available for important usage" counts purgeable space, which is what Finder shows as available;
    // "available" is what's free this second. The difference is space macOS frees when it needs room.
    let now = Int64(v?.volumeAvailableCapacity ?? 0)
    var free = v?.volumeAvailableCapacityForImportantUsage ?? now
    if free <= 0 { free = now }
    return ["total": total, "used": total - free, "free": free, "freeNow": min(now, free), "purgeable": max(0, free - now)]
}

/// What this Mac calls the Trash. macOS says "Bin" in British, Australian and Indian English (and gives British English
/// to most other English regions) and "Trash" elsewhere; this asks which of Finder's languages the person gets.
let BIN: String = {
    let finder = Bundle(path: "/System/Library/CoreServices/Finder.app")?.localizations ?? []
    let lang = Bundle.preferredLocalizations(from: finder, forPreferences: Locale.preferredLanguages).first ?? "en"
    return ["en_GB", "en_AU", "en_IN", "en-GB", "en-AU", "en-IN"].contains(lang) ? "Bin" : "Trash"
}()

extension Store {
    /// A made-up forecast for practice copies: free space falling for 16 days, with a wobble, ending at today's figure.
    static func practiceForecast(free: Int64) -> [String: Any] {
        let now = Date().timeIntervalSince1970, perDay = 1_400_000_000.0
        var line: [[Double]] = []
        for i in stride(from: 16, through: 0, by: -1) {
            let d = Double(i), wobble: Double = sin(d * 1.7) * perDay * 0.6, step: Double = i % 5 == 0 ? perDay * 0.8 : 0
            line.append([now - d * 86400, Double(free) + perDay * d + wobble + step])
        }
        let days = (Double(free) / perDay).rounded()
        return ["days": days, "at": now + days * 86400, "perDay": perDay, "from": now - 16 * 86400, "line": line]
    }

    func statusJSON() -> [String: Any] {
        progressLock.lock(); let seen = filesSeen, cur = current; progressLock.unlock()
        let disk = diskInfo(), disks = Disks.json()   // volume queries: keep them outside the lock the main thread also takes
        // practice copies show a made-up forecast so the line can be looked at; the real one needs steady weeks
        let forecast: [String: Any]? = REVIEW ? Store.practiceForecast(free: disk["free"] as? Int64 ?? 0) : History.forecastNow()
        lock.lock(); defer { lock.unlock() }
        let end = finished > started ? finished : Date().timeIntervalSince1970
        var out: [String: Any] = [
            "scanning": scanning, "files": seen, "current": cur.replacingOccurrences(of: HOME, with: "~"),
            "elapsed": started > 0 ? ((end - started) * 10).rounded() / 10 : 0,
            // a saved map counts as ready: the page shows it while a rescan runs quietly behind it
            "ready": root != nil, "loading": loading, "refreshing": (scanning || Live.catchingUp) && root != nil, "saved": fromSaved,
            "live": Live.current && !scanning,   // changes on disk reach the map by themselves
            "scannedAt": root != nil ? finished : 0, "generation": generation, "since": root != nil ? baselineAt : 0,
            "disk": disk, "roots": roots, "home": HOME, "bin": BIN, "binSize": (index[trashPath]?.size ?? 0) + trashedSince, "practice": REVIEW,
            "disks": disks, "onMac": Disks.current.mac, "diskName": Disks.current.name, "trash": trashPath,
            "uiSounds": UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true,   // the Mac's "play user interface sound effects"
            "denied": denied.count, "access": access,
            "dupes": ["status": dupes.status, "progress": dupes.progress, "total": dupes.total, "rev": dupes.rev],
        ]
        if let f = forecast { out["forecast"] = f }
        return out
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
            // a drive is mapped whole, so the path starts at the drive itself, under its own name
            if x.name.hasPrefix("/"), !Disks.current.mac { crumbs.append(["name": Disks.current.name, "path": x.path]); break }
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

    /// Folders that browsers and apps built on them keep caches in, inside the app's own data folder.
    private static let cacheFolders: Set<String> = ["Cache", "Code Cache", "GPUCache", "CachedData", "CacheStorage", "ScriptCache", "DawnCache",
        "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache", "GraphiteDawnCache", "ShaderCache", "component_crx_cache"]
    /// Tools' folders inside ~/.cache that only hold downloads the tool fetches again by itself.
    private static let toolCaches: Set<String> = ["pip", "uv", "yarn", "bun", "deno", "go-build", "node-gyp", "electron", "electron-builder", "typescript", "turbo"]

    /// The Clean up list. Each item is one of two things Rumi can do with it:
    ///   - move it to the Trash (you can undo): the default
    ///   - show you how ("act": "how"): a tool's own cleanup command, which can't be undone, or something Rumi won't touch
    /// "safety" is safe, review (Check first) or keep (Won't touch). "open" names the app that's running and has to quit
    /// first. "parts" lists the folders when one row stands for several.
    func suggestionsJSON() -> (Int, [String: Any]) {
        let now = Date().timeIntervalSince1970
        var out: [[String: Any]] = []
        var appKey: [String: String] = [:]     // path → the app it belongs to, as a bundle id or a folder name
        var titleID: [Int: String] = [:]       // rows whose title is an app's bundle id, named after the lock is let go
        @discardableResult func add(_ group: String, _ title: String, _ why: String, _ path: String, _ size: Int64, _ safety: String, _ extra: [String: Any] = [:]) -> Bool {
            guard size >= 20 * 1024 * 1024 else { return false }
            var d: [String: Any] = ["group": group, "title": title, "why": why, "path": path, "size": size, "safety": safety]
            for (k, v) in extra { d[k] = v }
            out.append(d)
            return true
        }
        func how(_ title: String, _ why: String, _ path: String, _ size: Int64, _ safety: String, cmd: String? = nil, steps: [String]) {
            var h: [String: Any] = ["steps": steps]
            if let c = cmd { h["cmd"] = c }
            add("How to", title, why, path, size, safety, ["kind": "dir", "act": "how", "how": h])
        }
        // The tree is read under the lock (a trash edits it). The slow lookups (app names, what's running, last-used dates)
        // wait until after.
        lock.lock()
        guard root != nil else { lock.unlock(); return (409, ["error": "not ready"]) }
        let idx = index, big = bigFiles
        func get(_ rel: String) -> Dir? { idx[HOME + "/" + rel] }

        // caches: ~/Library/Caches, one row per app
        if let caches = get("Library/Caches") {
            let mine: Set<String> = ["com.clinton.rumi", "StorageMap", "storage-map"]
            var n = 0
            for ch in caches.dirs.sorted(by: { $0.size > $1.size }) where !mine.contains(ch.name) && n < 25 {
                if add("Caches", ch.name, "", ch.path, ch.size, "safe", ["kind": "dir"]) {
                    n += 1; titleID[out.count - 1] = ch.name
                    if !ch.name.hasPrefix("com.apple.") { appKey[ch.path] = ch.name }   // macOS's own aren't an app you can quit
                }
            }
        }
        // caches that apps keep inside their own data folder (browsers, and apps built on one). They join the app's row
        // above when it has one, once names are known
        var inData: [(name: String, parts: [[String: Any]], size: Int64)] = []
        if let support = get("Library/Application Support") {
            for app in support.dirs where app.name != "com.clinton.rumi" {
                var parts: [Dir] = []
                func find(_ d: Dir, _ depth: Int) {
                    for ch in d.dirs {
                        if Store.cacheFolders.contains(ch.name) { parts.append(ch) } else if depth < 4 { find(ch, depth + 1) }
                    }
                }
                find(app, 1)
                parts = parts.filter { $0.size >= 1 << 20 }.sorted { $0.size > $1.size }
                guard !parts.isEmpty else { continue }
                inData.append((app.name.prefix(1).uppercased() + app.name.dropFirst(), parts.map { ["path": $0.path, "size": $0.size] }, parts.reduce(0) { $0 + $1.size }))
                for p in parts { appKey[p.path] = app.name }
            }
        }
        // sandboxed apps keep theirs in a container
        if let boxes = get("Library/Containers") {
            for box in boxes.dirs {
                guard let c = idx[box.path + "/Data/Library/Caches"] else { continue }
                if add("Caches", box.name, "", c.path, c.size, "safe", ["kind": "dir"]) {
                    titleID[out.count - 1] = box.name
                    if !box.name.hasPrefix("com.apple.") { appKey[c.path] = box.name }
                }
            }
        }
        // ~/.cache: each tool's folder by itself. Only the ones known to refill on their own are Safe.
        if let dot = get(".cache") {
            for ch in dot.dirs {
                let known = Store.toolCaches.contains(ch.name)
                add("Caches", "\(ch.name) cache", known ? "Downloaded again when needed" : "A tool's downloads · see what's inside", ch.path, ch.size, known ? "safe" : "review", ["kind": "dir"])
            }
        }
        if let n = get(".npm/_cacache") ?? get(".npm") { add("Caches", "npm cache", "Downloaded again when needed", n.path, n.size, "safe", ["kind": "dir"]) }
        if let n = get(".gradle/caches") { add("Caches", "Gradle cache", "Downloaded again when needed", n.path, n.size, "safe", ["kind": "dir"]) }
        if let n = get(".cargo/registry") { add("Caches", "Rust package downloads", "Downloaded again when needed", n.path, n.size, "safe", ["kind": "dir"]) }

        for (rel, label, why) in [
            ("Library/Developer/Xcode/DerivedData", "Xcode build files", "Rebuilt on your next build"),
            ("Library/Developer/Xcode/iOS DeviceSupport", "Old iPhone debugging files", "Come back when you plug in a device"),
            ("Library/Developer/Xcode/Archives", "Xcode archives", "Keep any you still ship"),
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
        if let tr = idx[trashPath] {
            add("Trash", "Trash", "", tr.path, tr.size + trashedSince, "safe", ["action": "empty"])
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

        // ---- things Rumi shows you how to clear, and doesn't clear itself ----
        // A tool's own cleanup can't be undone, so Rumi gives the command and leaves running it to you.
        if let n = get("Library/pnpm/store") {
            how("pnpm store", "Shared with your projects", n.path, n.size, "safe",
                cmd: "pnpm store prune", steps: ["Run this in Terminal.", "It removes packages no project uses. It can't be undone."])
        }
        if let n = get("go/pkg/mod") {
            how("Go module downloads", "Downloaded again when a project needs them", n.path, n.size, "safe",
                cmd: "go clean -modcache", steps: ["Run this in Terminal.", "Go downloads modules again on the next build. It can't be undone."])
        }
        if let n = get("Library/Developer/CoreSimulator/Devices") {
            how("iPhone simulators", "Old ones can go", n.path, n.size, "review",
                cmd: "xcrun simctl delete unavailable", steps: ["Run this in Terminal.", "It removes simulators for versions you no longer have. Their test data goes too."])
        }
        // A virtual machine an app keeps in its data folder (a disk image of 2 GB or more) is often the biggest single thing
        // there. It can hold your work, and the app has to be the one to remove or rebuild it.
        var machines: [String: String] = [:]   // folder → the app's folder name or bundle id
        for area in ["/Library/Application Support/", "/Library/Containers/"] {
            let base = HOME + area
            for b in big where b.alloc >= Int64(2) << 30 && b.path.hasPrefix(base)
                && ["img", "qcow2", "vmdk", "vdi", "raw"].contains(fileExt((b.path as NSString).lastPathComponent)) {
                let parts = b.path.dropFirst(base.count).split(separator: "/")
                if parts.count >= 3 { machines[base + parts[0] + "/" + parts[1]] = String(parts[0]) }   // app / folder / … / image
            }
        }
        var machineRows: [(Int, String)] = []
        for (p, app) in machines.sorted(by: { $0.key < $1.key }) {
            guard let d = idx[p] else { continue }
            let n = out.count
            how("\(app)'s virtual machine", "Can hold your work", d.path, d.size, "keep",
                steps: ["Quit \(app).", "Look for a reset or clean-up option in \(app) first.", "Or delete this folder in Finder. \(app) may download it again."])
            if out.count > n { machineRows.append((n, app)); appKey[d.path] = app }
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
        let installed = (idx["/Applications"]?.dirs ?? []).filter { $0.name.hasSuffix(".app") }.map { $0.path }
        let scan = finished
        lock.unlock()

        for (i, id) in titleID { out[i]["title"] = cacheName(id) }
        for (i, app) in machineRows where app.contains(".") && !app.contains(" ") {   // a container is named by bundle id
            let name = cacheName(app)
            out[i]["title"] = "\(name)'s virtual machine"
            if var h = out[i]["how"] as? [String: Any], let steps = h["steps"] as? [String] { h["steps"] = steps.map { $0.replacingOccurrences(of: app, with: name) }; out[i]["how"] = h }
        }
        // one row per app: an app can keep caches in several places (two folders in Caches, and more in its own data)
        func parts(_ d: [String: Any]) -> [[String: Any]] { d["parts"] as? [[String: Any]] ?? [["path": d["path"] ?? "", "size": d["size"] ?? 0]] }
        func join(_ i: Int, _ more: [[String: Any]], _ size: Int64) { out[i]["parts"] = parts(out[i]) + more; out[i]["size"] = (out[i]["size"] as? Int64 ?? 0) + size }
        func row(named n: String, before end: Int) -> Int? {
            out[..<end].firstIndex { $0["group"] as? String == "Caches" && $0["safety"] as? String == "safe" && ($0["title"] as? String)?.lowercased() == n.lowercased() }
        }
        for i in titleID.keys.sorted().reversed() {   // later rows fold into the first with the same name
            guard let t = out[i]["title"] as? String, !t.hasPrefix("macOS"), let first = row(named: t, before: i) else { continue }
            join(first, parts(out[i]), out[i]["size"] as? Int64 ?? 0)
            out.remove(at: i)
        }
        for d in inData {
            if let i = row(named: d.name, before: out.count) { join(i, d.parts, d.size) }
            else if let first = d.parts.first?["path"] as? String { add("Caches", d.name, "", first, d.size, "safe", ["kind": "dir", "parts": d.parts]) }
        }
        // Homebrew keeps every old version of what it installs, outside the folders Rumi maps
        if let (cellar, size) = brewOld(scan) {
            how("Homebrew old versions", "Kept after every update", cellar, size, "safe",
                cmd: "brew cleanup", steps: ["Run this in Terminal.", "It removes old versions and downloads. It can't be undone."])
        }
        for (name, path, size) in apps {
            if let last = lastUsed(path), (now - last) / 86400 > 120 {
                add("Apps", String(name.dropLast(4)), "Unused \(Int((now - last) / 86400 / 30)) months", path, size, "review", ["kind": "app"])
            }
        }
        // an app that's open has to quit before its caches go
        let running = runningApps()
        var all = Set<String>()
        for i in out.indices {
            let paths = (out[i]["parts"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? [out[i]["path"] as? String ?? ""]
            if out[i]["act"] as? String != "how" { all.formUnion(paths) }
            guard let first = paths.first(where: { appKey[$0] != nil }), let key = appKey[first] else { continue }
            if let app = openApp(for: key, in: running) { out[i]["open"] = app }
            if let icon = appPath(for: key, in: paths, title: out[i]["title"] as? String ?? "", among: installed) { out[i]["app"] = icon }   // the row shows the app's icon
        }
        lock.lock(); suggested = all; suggestedApp = appKey; lock.unlock()
        return (200, ["items": out])
    }

    /// Old versions Homebrew still keeps: where its cellar is and how much they take. Measured once per scan.
    private func brewOld(_ scan: Double) -> (String, Int64)? {
        lock.lock(); let kept = brewKept; lock.unlock()
        if let k = kept, k.scan == scan { return k.size > 0 ? (k.cellar, k.size) : nil }
        let fm = FileManager.default
        guard let cellar = ["/opt/homebrew/Cellar", "/usr/local/Cellar"].first(where: { fm.fileExists(atPath: $0) }) else { return nil }
        var total: Int64 = 0
        for formula in (try? fm.contentsOfDirectory(atPath: cellar)) ?? [] {
            let dir = cellar + "/" + formula
            let versions = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.map { dir + "/" + $0 }
            guard versions.count > 1 else { continue }
            func made(_ p: String) -> Date { ((try? fm.attributesOfItem(atPath: p))?[.creationDate] as? Date) ?? .distantPast }
            for old in versions.sorted(by: { made($0) < made($1) }).dropLast() { total += Frees.measure(old, workers: 2).frees }
        }
        lock.lock(); brewKept = (scan, cellar, total); lock.unlock()
        return total > 0 ? (cellar, total) : nil
    }

    /// Where the app that owns a cache is installed, so its row can show the app's icon. `key` is how the cache folder
    /// is named: a bundle id, or a plain name ("Player", or a maker's name with the app's folder inside it).
    private func appPath(for key: String, in paths: [String], title: String, among installed: [String]) -> String? {
        func norm(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        var found: String?
        if key.contains("."), !key.contains(" ") {
            var parts = key.split(separator: ".").map(String.init)
            while found == nil, parts.count >= 3 {   // a helper's id ("com.example.player.helper") leads back to its app
                found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: "."))?.path
                parts.removeLast()
            }
        } else {
            // "Maker/App/…": the app is named after the folder, the folder inside it, or both together
            let inside = Set(paths.compactMap { $0.components(separatedBy: "/" + key + "/").dropFirst().first?.split(separator: "/").first.map(String.init) })
            var names = Set(([key, title] + inside.map { key + $0 }).map(norm).filter { $0.count >= 3 })
            if names.contains("code") { names.insert("visualstudiocode") }   // its data folder is just "Code"
            found = installed.first { names.contains(norm((($0 as NSString).lastPathComponent as NSString).deletingPathExtension)) }
        }
        guard let f = found, pathInRoots(f) != nil else { return nil }   // the page can only load icons from the mapped folders
        return f
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
                    // (two names of one hard-linked file do too)
                    let fam = same.map { b -> String? in
                        var st = stat()
                        if lstat(b.path, &st) == 0, st.st_nlink > 1 { return "link-\(st.st_dev)-\(st.st_ino)" }
                        return cloneFamily(b.path)
                    }
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

private var scannedRoots = Store.shared.roots.map { realPath($0) ?? $0 }
/// Another disk is on screen.
func rootsChanged() { scannedRoots = Store.shared.roots.map { realPath($0) ?? $0 } }

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

/// The apps that are open now (not Rumi, not background-only helpers).
func runningApps() -> [(name: String, id: String, file: String, dock: Bool)] {
    let read = {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited && $0.processIdentifier != getpid() }
            .map { (name: $0.localizedName ?? "", id: $0.bundleIdentifier ?? "", file: $0.bundleURL?.deletingPathExtension().lastPathComponent ?? "", dock: $0.activationPolicy == .regular) }
    }
    return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
}

/// The open app a cache or data folder belongs to, if any. `key` is how the folder is named: a bundle id
/// ("com.example.player") or a plain name ("Player", or a maker's name that holds its apps). An app in the Dock matches
/// loosely (by its maker, or a name that starts or ends with the folder's); a background helper only by its exact name.
func openApp(for key: String, in apps: [(name: String, id: String, file: String, dock: Bool)]) -> String? {
    func norm(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
    let k = norm(key), isID = key.contains(".") && !key.contains(" ")
    guard k.count >= 3 else { return nil }
    for a in apps where !a.name.isEmpty {
        let id = a.id.lowercased()
        if isID {
            let kid = key.lowercased()
            if !id.isEmpty, id == kid || kid.hasPrefix(id + ".") || id.hasPrefix(kid + ".") { return a.name }
            continue
        }
        let names = [norm(a.name), norm(a.file)]
        if names.contains(k) { return a.name }
        guard a.dock else { continue }
        if id.split(separator: ".").contains(where: { norm(String($0)) == k }) { return a.name }
        if k.count >= 4, names.contains(where: { $0.hasPrefix(k) || $0.hasSuffix(k) }) { return a.name }
    }
    return nil
}

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
            "try", "set bounds of w to b", "end try", "try", "if (item 2 of argv) is \"1\" then select f", "end try", "activate", "end tell", "end run",
        ], args: [path, select ? "1" : "0", String(left), String(top), String(left + Int(w)), String(top + Int(h))])
        if !ok {   // Finder couldn't make the window at all: the plain way
            DispatchQueue.main.async {
                if select { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } else { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
        }
    }
    return [left, top, left + Int(w), top + Int(h)]
}

/// Finder does the deleting so "Put Back" works, and everything goes in one request: one move and one sound, however
/// many things were picked. Whatever Finder leaves behind goes through the Trash API, one at a time.
/// Returns, for each path, whether it went, why not, and where it landed in the Trash (so Rumi can undo).
/// A link is never followed.
func moveToTrash(_ paths: [String]) -> [String: (ok: Bool, why: String, landed: String?)] {
    var res: [String: (ok: Bool, why: String, landed: String?)] = [:]
    var ids: [String: UInt64] = [:]   // each one's file number: it keeps it in the Trash, whatever name it's given there
    var viaFinder: [String] = []
    func fileID(_ p: String) -> UInt64? { var st = stat(); return lstat(p, &st) == 0 ? UInt64(st.st_ino) : nil }
    for p in paths where ids[p] == nil {
        var st = stat()
        guard lstat(p, &st) == 0 else { res[p] = (false, "no longer exists", nil); continue }
        ids[p] = UInt64(st.st_ino)
        if st.st_mode & S_IFMT != S_IFLNK { viaFinder.append(p) }   // Finder's alias would resolve a link; the Trash API moves the link itself
    }
    var err = ""
    if !viaFinder.isEmpty {
        let (ok, e, out) = osascript([
            "on run argv", "set fs to {}", "repeat with p in argv", "set end of fs to (POSIX file (contents of p) as alias)", "end repeat",
            "set out to \"\"", "with timeout of 600 seconds", "tell application \"Finder\"", "set t to delete fs",
            "if class of t is not list then set t to {t}",
            "repeat with x in t", "set out to out & POSIX path of (x as alias) & linefeed", "end repeat",
            "end tell", "end timeout", "return out", "end run"], args: viaFinder)
        if !ok { err = e }
        var landed: [UInt64: String] = [:]
        for line in out.split(separator: "\n") {
            let l = line.hasSuffix("/") && line.count > 1 ? String(line.dropLast()) : String(line)
            if let id = fileID(l) { landed[id] = l }
        }
        let gone = viaFinder.filter { fileID($0) == nil }
        // Finder stopped part-way, or its answer couldn't be read: what did move is found by looking in the Trash
        if gone.contains(where: { landed[ids[$0] ?? 0] == nil }) {
            let tp = Store.shared.trashPath
            for n in (try? FileManager.default.contentsOfDirectory(atPath: tp)) ?? [] { if let id = fileID(tp + "/" + n), landed[id] == nil { landed[id] = tp + "/" + n } }
        }
        for p in gone { res[p] = (true, "", landed[ids[p] ?? 0]) }
    }
    for p in paths where res[p] == nil {
        var l: NSURL?
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &l); res[p] = (true, "", l?.path) }
        catch { res[p] = (false, String((err.isEmpty ? error.localizedDescription : err).prefix(200)), nil) }
    }
    return res
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
    let apps = Store.shared.suggestedApp
    Store.shared.lock.unlock()
    let running = apps.isEmpty ? [] : runningApps()
    func exists(_ f: String) -> Bool { var st = stat(); return lstat(f, &st) == 0 }
    // Decide first, then move everything in one go. Copies are decided last, and what's already set to move counts as
    // gone, so a folder holding another copy is out of the way when the copy is checked.
    let copy = asked.map { sets[($0 as NSString).standardizingPath] != nil ? 1 : 0 }
    let order = asked.indices.sorted { (copy[$0], $0) < (copy[$1], $1) }
    var results = [[String: Any]](repeating: [:], count: asked.count)
    var go: [(i: Int, path: String, size: Int64?)] = [], moving: [String] = []
    func there(_ f: String) -> Bool { exists(f) && !moving.contains { f == $0 || f.hasPrefix($0 + "/") } }
    for i in order {
        var (path, why) = trashCheck(asked[i])
        if let p = path, let groups = sets[p], groups.contains(where: { g in !g.contains { $0 != p && there($0) } }) {
            why = "it's the last copy"
        } else if let p = path, let key = apps[p], let app = openApp(for: key, in: running) {
            why = "\(app) is open. Quit it first"   // its cache is in use: removing it under the app can break what it's doing
        } else if let p = path {
            var st = stat(); let size: Int64? = lstat(p, &st) == 0 ? sharedAlloc(st) : nil   // small files aren't in the tree: say how much left
            go.append((i, p, size)); moving.append(p)
        }
        results[i] = ["path": path ?? asked[i], "ok": false, "error": why]
    }
    let moved = moveToTrash(go.map { $0.path })
    var done = Set<String>()
    for g in go {
        guard let m = moved[g.path] else { continue }
        results[g.i]["ok"] = m.ok; results[g.i]["error"] = m.why
        if let l = m.landed { results[g.i]["trashed"] = l }
        guard m.ok, done.insert(g.path).inserted else { continue }
        let S = Store.shared
        S.lock.lock(); let before = S.root?.size ?? 0; S.detach(g.path, size: g.size); S.trashedSince += max(0, before - (S.root?.size ?? 0)); S.lock.unlock()
        if let l = m.landed { undoLock.lock(); undoable.insert(undoKey(l, g.path)); undoLock.unlock() }
    }
    if results.contains(where: { $0["ok"] as? Bool == true }) { Snapshot.saveSoon(); Frees.forget(results.filter { $0["ok"] as? Bool == true }.compactMap { $0["path"] as? String }) }   // so trashed files don't reappear next launch
    return ["results": results]
}

/// Empty the Trash. Rumi removes what's in it itself: asked to do it, Finder puts its own "are you sure?" behind Rumi's
/// window (Rumi has already asked) and refuses anything an app in the background still has open.
/// Without access to the Trash folder, Finder is asked after all.
func emptyTrashJSON() -> [String: Any] {
    var ok = false, err = ""
    if let left = removeContents(of: Store.shared.trashPath) {
        ok = left.count == 0
        if !ok { err = "\(left.count) item\(left.count == 1 ? "" : "s") stayed. \(left.why)" }
    } else {
        (ok, err, _) = osascript(["with timeout of 600 seconds", "tell application \"Finder\" to empty trash", "end timeout"])
    }
    undoLock.lock(); undoable.removeAll(); undoLock.unlock()
    if ok { Store.shared.emptiedTrash(); Snapshot.saveSoon() } else { Store.shared.startScan() }   // partly emptied: measure again
    return ["ok": ok, "error": String(err.prefix(200))]
}

/// Delete everything inside a folder for good. Links are removed, never followed. Returns how many things stayed and
/// why the first one did, or nil if the folder can't be read.
func removeContents(of dir: String) -> (count: Int, why: String)? {
    let fm = FileManager.default
    var st = stat()
    guard lstat(dir, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
    var left = 0, why = ""
    for n in names where n != ".DS_Store" {   // Finder's own note of where things came from
        do { try fm.removeItem(atPath: dir + "/" + n) } catch { left += 1; if why.isEmpty { why = error.localizedDescription } }
    }
    return (left, why)
}
