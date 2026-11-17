// Rumi — app entry: one window holding the web page, Mac menus, and the Full Disk Access check.
import AppKit
import WebKit

enum Access {
    /// Full Disk Access can't be queried directly, so try to read places only it unlocks.
    static func granted() -> Bool {
        let probes = [HOME + "/Library/Safari", HOME + "/Library/Application Support/com.apple.TCC/TCC.db",
                      "/Library/Application Support/com.apple.TCC/TCC.db"]
        var sawDenied = false
        for p in probes {
            var isDir: ObjCBool = false
            let fd = open(p, O_RDONLY)
            if fd >= 0 { close(fd); if FileManager.default.fileExists(atPath: p, isDirectory: &isDir) { return true } }
            if errno == EPERM || errno == EACCES { sawDenied = true }
        }
        return !sawDenied
    }

    static func refresh(scan: Bool = true) {
        let S = Store.shared
        if S.access == "needed", granted() || UserDefaults.standard.bool(forKey: "skippedFullDiskAccess") {
            S.access = granted() ? "granted" : "skipped"
            if scan { S.startScan(quiet: true) }
        }
    }

    static func skip() {
        UserDefaults.standard.set(true, forKey: "skippedFullDiskAccess")
        Store.shared.access = "skipped"
        Store.shared.startScan()
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    /// The main window's web view. nil while the window is closed and its page has been let go.
    var web: WKWebView?
    let scheme = SchemeHandler()
    let bridge = Bridge()

    /// A web view configuration for the app's own pages: the rumi:// scheme, the action bridge and this launch's token.
    /// The main window and the menu-bar search panel each get one.
    func makeConfig() -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(scheme, forURLScheme: "rumi")
        cfg.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "rumi")
        // this launch's API token goes to the app's own page only (the viewer's pages are frames, on another origin)
        let boot = "if (location.protocol === 'rumi:' && location.host === 'app') try { sessionStorage.setItem('sm-token', \(String(data: jsonData([SESSION_TOKEN]), encoding: .utf8)!)[0]); } catch (e) {}"
        cfg.userContentController.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // inside a web page shown in the viewer, Esc still closes the viewer (the page can't do anything else with this)
        let frames = "if (window !== top) addEventListener('keydown', e => { if (e.key === 'Escape') parent.postMessage({ rumiKey: 'Escape' }, '*'); }, true);"
        cfg.userContentController.addUserScript(WKUserScript(source: frames, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        return cfg
    }

    /// The main window's web view.
    func makeWebView() -> WKWebView {
        let v = RumiWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), configuration: makeConfig())
        v.isInspectable = DEV_MODE
        v.navigationDelegate = self
        v.uiDelegate = self
        v.underPageBackgroundColor = PAPER
        return v
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenus()
        // started by macOS at login: stay in the menu bar, with no window, no page and no map in memory until one is asked for
        let ev = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = ev?.eventID == AEEventID(kAEOpenApplication) && ev?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        if !atLogin { web = makeWebView() }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Rumi"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = PAPER
        window.appearance = NSAppearance(named: .aqua)
        window.minSize = NSSize(width: 1040, height: 680)
        window.contentView = web ?? NSView()
        window.isReleasedWhenClosed = false
        window.delegate = self
        let testRun = CommandLine.arguments.contains("--snapshot")
        if !testRun {   // test renders happen off-screen and must not save that position
            if !window.setFrameUsingName("RumiMain") { window.center() }
            // a saved position on a screen that's gone (or mostly off-screen) comes back centred
            let visible = NSScreen.screens.contains { $0.visibleFrame.intersection(window.frame).width > 400 && $0.visibleFrame.intersection(window.frame).height > 300 }
            if !visible { window.center() }
            window.setFrameAutosaveName("RumiMain")
        }
        if !atLogin {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if !testRun {   // every 20 s: with the window closed and search unused for a while, let memory go
            Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.idleTick() }
        }
        // search from anywhere: the menu-bar cartridge and its shortcut (not in test runs, which would add a second cartridge)
        QuickSearch.shared.makeConfig = { [unowned self] in self.makeConfig() }
        QuickSearch.shared.showMain = { [unowned self] in self.showMainWindow() }
        if !testRun { QuickSearch.shared.install(); QuickSearch.shared.registerShortcut() }

        if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
            // test mode: render off-screen, save a PNG of the window, report a few checks, quit
            launchedAt = Date()
            Store.shared.loading = FileManager.default.fileExists(atPath: Snapshot.treeURL.path)
            DispatchQueue.global(qos: .userInteractive).async { Store.shared.loadSaved() }
            Store.shared.access = "granted"; Store.shared.startScan()
            window.setFrameOrigin(NSPoint(x: -6000, y: 0))
            let out = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "/tmp/rumi.png"
            let page = CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : "index.html"
            web?.load(URLRequest(url: URL(string: "rumi://app/" + page)!))
            snapshot(to: out, tries: 0)
            return
        }
        if atLogin {
            // nothing is on screen: the saved map stays on disk, and the quiet rescan waits three minutes for login to settle
            Store.shared.unloaded = FileManager.default.fileExists(atPath: Snapshot.treeURL.path)
            Access.refresh(scan: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) { if Store.shared.access != "needed" { Store.shared.startScan(quiet: true) } }
        } else {
            // last launch's map opens right away; the scan Access.refresh starts then refreshes it quietly
            Store.shared.loading = FileManager.default.fileExists(atPath: Snapshot.treeURL.path)
            DispatchQueue.global(qos: .userInteractive).async { Store.shared.loadSaved() }
            Access.refresh()
            web?.load(URLRequest(url: URL(string: "rumi://app/index.html")!))
        }
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 30) { Viewer.prune() }
    }

    var launchedAt = Date()
    /// Test mode, part 2: wait for the quiet rescan to land and check the map is still drawn.
    private func afterRefresh(tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            let probe = "(() => ({ refreshing: !!(status && status.refreshing), button: document.getElementById('rescan-l').textContent, tip: document.getElementById('rescan').title, blocks: document.querySelectorAll('#map .b').length, scanningScreen: !document.getElementById('scanning').hidden }))()"
            guard let web = self.web else {   // the page was let go by a test: wait out the hold, then quit
                if Date() < self.holdUntil && tries < 600 { return self.afterRefresh(tries: tries + 1) }
                return NSApp.terminate(nil)
            }
            web.evaluateJavaScript(probe) { res, _ in
                let r = res as? [String: Any] ?? [:]
                if tries == 0 { print("while updating:", r) }
                if ((r["refreshing"] as? Bool ?? false) || Date() < self.holdUntil) && tries < 600 { return self.afterRefresh(tries: tries + 1) }
                print(String(format: "after update (%.1f s):", Date().timeIntervalSince(self.launchedAt)), r)
                NSApp.terminate(nil)
            }
        }
    }

    private func snapshot(to out: String, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            let probe = "(() => ({ blocks: document.querySelectorAll('#map .b').length, scanning: !document.getElementById('scanning').hidden, rows: document.querySelectorAll('.row').length }))()"
            web?.evaluateJavaScript(probe) { res, _ in
                let r = res as? [String: Any] ?? [:]
                let ready = (r["blocks"] as? Int ?? 0) > 0 && !(r["scanning"] as? Bool ?? true)
                if !ready && tries < 480 { return self.snapshot(to: out, tries: tries + 1) }
                print(String(format: "first map on screen after %.2f s", Date().timeIntervalSince(self.launchedAt)))
                self.web?.evaluateJavaScript("JSON.stringify(performance.getEntriesByType('mark').map(m => [m.name, Math.round(m.startTime)]).concat([['nav', Math.round(performance.timeOrigin - \(self.launchedAt.timeIntervalSince1970 * 1000))]]))") { m, _ in print("page marks (ms):", m ?? "") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.web?.callAsyncJavaScript("return await NATIVE.postMessage({ path: '/native/ping', body: {} })", in: nil, in: .page) { bridge in
                        print("probe:", r, "bridge:", (try? bridge.get()) ?? "failed")
                        let ql = QuickLook.shared.handle(["/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns"], mode: "toggle")
                        print("quick look opens:", ql, "· closes:", !QuickLook.shared.handle([], mode: "close"))
                        // RUMI_EVAL: run a test script in the page first (it may await), print what it returns
                        let js = ProcessInfo.processInfo.environment["RUMI_EVAL"] ?? "return null"
                        self.web?.callAsyncJavaScript(js, in: nil, in: .page) { res in
                        if ProcessInfo.processInfo.environment["RUMI_EVAL"] != nil { print("eval:", (try? res.get()) ?? "failed: \(res)") }
                        self.web?.takeSnapshot(with: nil) { img, _ in
                            if writePNG(img, to: out) { print("snapshot:", out) }
                            self.afterRefresh(tries: 0)
                        }
                        }
                    }
                }
            }
        }
    }

    func applicationDidBecomeActive(_ note: Notification) { Access.refresh() }
    // Closing the window leaves Rumi in the menu bar, so search stays one click away. ⌘Q (or the cartridge's menu) quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { showMainWindow() }; return true }

    // While its window is closed Rumi only needs to answer searches, so the map's page is let go a minute after the window
    // closes (about 100 to 200 MB back) and loaded again when the window returns. The map of the disk itself stays in memory.
    private var unloadTimer: DispatchWorkItem?
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window, !CommandLine.arguments.contains("--snapshot") else { return }
        unloadTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in if self?.window.isVisible == false { self?.unloadPage() } }
        unloadTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: t)
    }
    /// With the window closed and its page gone, Rumi only answers searches. Once search has been unused for a while its
    /// panel goes too (2 minutes), and so does the map of the disk (45 seconds); both come back when they're asked for.
    func idleTick() {
        let Q = QuickSearch.shared
        guard web == nil, !window.isVisible, !Q.isOpen else { return }
        let quiet = Date().timeIntervalSince(Q.lastUsed)
        if quiet > 120 { Q.releasePanel() }
        if quiet > 45 { Store.shared.unload() }
    }

    func unloadPage() {
        guard web != nil else { return }
        Store.shared.viewerOpen = false
        // the web view itself goes: only that ends its helper process and frees the memory (a blank page stays cached)
        window.contentView = NSView()
        web = nil
    }

    @objc func showMainWindow() {
        unloadTimer?.cancel()
        Store.shared.ensureLoaded()
        if web == nil { web = makeWebView(); window.contentView = web; web?.load(URLRequest(url: URL(string: "rumi://app/index.html")!)) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Test runs only (--snapshot): how long search and the window take to come back when they were kept in memory, and
    /// when they had been let go. Prints one line per case.
    func runTiming() {
        let Q = QuickSearch.shared
        func say(_ s: String) { print(s); fflush(stdout) }
        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
        func dropMap() { for _ in 0..<50 where !Store.shared.unload() { Thread.sleep(forTimeInterval: 0.1) } }
        // the window: from asking for it until the map is drawn
        func reopen(_ label: String, then: @escaping () -> Void) {
            let t0 = Date()
            showMainWindow()
            window.setFrameOrigin(NSPoint(x: -6000, y: 0))
            func poll() {
                web?.evaluateJavaScript("typeof status === 'object' && !!status && !!status.ready && document.querySelectorAll('#map .b').length > 0 && document.getElementById('scanning').hidden") { r, _ in
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    if r as? Bool == true || ms > 20000 { say("timing · \(label): \(ms) ms"); return then() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }
                }
            }
            poll()
        }
        Q.timeOpen { first in say("timing · search, first ever open: \(first)")
        after(2) { Q.timeOpen { r in say("timing · search, all kept: \(r)")
        after(1) { dropMap(); say("map let go: \(Store.shared.root == nil)")
        after(2) { Q.timeOpen { r in say("timing · search, map let go: \(r)")
        after(1) { Q.releasePanel(); dropMap()
        after(3) { Q.timeOpen { r in say("timing · search, panel and map let go: \(r)")
        after(1) { self.window.orderOut(nil)
        after(1) { reopen("window, all kept") {
        after(2) { self.window.orderOut(nil); self.unloadPage()
        after(3) { reopen("window, page let go") {
        after(2) { self.window.orderOut(nil); self.unloadPage(); Q.releasePanel(); dropMap(); say("map let go: \(Store.shared.root == nil)")
        after(3) { reopen("window, page and map let go") {
        // as after a start at login: nothing in memory and the quiet scan already running. The saved map must still show.
        after(2) { self.window.orderOut(nil); self.unloadPage(); dropMap(); Store.shared.startScan(quiet: true)
        after(3) { say("scan running: \(Store.shared.scanning), map in memory: \(Store.shared.root != nil)"); reopen("window, nothing kept and a scan running") {
            self.holdUntil = Date()
        } } } } } } } } } } } } } } } } } } } } }
    }

    private var mapAsk = 0
    /// From the menu-bar panel: show something on the map, once the page is up and the map is drawn. Both may have to come
    /// back first, and a first scan takes a while, so it keeps trying for a minute and a half. A newer ask replaces it.
    func showOnMap(_ item: [String: Any]) {
        showMainWindow()
        mapAsk += 1
        let ask = mapAsk, json = String(data: jsonData(item), encoding: .utf8) ?? "{}"
        func attempt(_ tries: Int) {
            guard ask == mapAsk else { return }
            web?.evaluateJavaScript("(() => { if (!(window.rumiShowOnMap && typeof status === 'object' && status && status.ready && document.querySelector('#map .b'))) return false; rumiShowOnMap(\(json)); return true; })()") { ok, _ in
                if ok as? Bool != true, tries < 300 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { attempt(tries + 1) } }
            }
        }
        attempt(0)
    }

    /// Test runs: don't quit before this time (a test that lets the page go needs the app to outlive it).
    var holdUntil = Date.distantPast

    // The window stays on rumi://app. A web page in the viewer (a sealed frame) may load its own folder over rumi://files
    // and its embeds (video players, maps) over the web; a link clicked in it opens in your browser, if it's a web or mail link.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = action.request.url else { return decisionHandler(.cancel) }
        let scheme = u.scheme?.lowercased() ?? ""
        if action.targetFrame?.isMainFrame == true {
            if scheme == "rumi" { return decisionHandler(u.host == "app" ? .allow : .cancel) }
            if scheme != "about" { NSWorkspace.shared.open(u); return decisionHandler(.cancel) }
            return decisionHandler(.allow)
        }
        if scheme == "rumi" {
            guard u.host == "files" else { return decisionHandler(.cancel) }   // the app's own page never runs inside the viewer
            if action.sourceFrame.isMainFrame { Pages.opened(u.path) }   // the app showing a page: that page's folder is what it may load
            return decisionHandler(.allow)
        }
        if action.navigationType == .linkActivated {
            if ["http", "https", "mailto"].contains(scheme) { NSWorkspace.shared.open(u) }
            return decisionHandler(.cancel)
        }
        decisionHandler(["http", "https", "data", "blob", "about"].contains(scheme) ? .allow : .cancel)
    }

    // MARK: menus

    @objc func rescan() { web?.evaluateJavaScript("document.getElementById('rescan').click()") }
    @objc func reloadPage() { web?.reload() }
    @objc func goBack() { web?.evaluateJavaScript("goBack()") }
    @objc func goForward() { web?.evaluateJavaScript("goForward()") }
    @objc func goUp() { web?.evaluateJavaScript("goUp()") }
    @objc func showAccess() { showMainWindow(); web?.evaluateJavaScript("window.showAccess && showAccess()") }

    private func buildMenus() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title); items.forEach(m.addItem)
            let host = NSMenuItem(); host.submenu = m; main.addItem(host); return m
        }
        func item(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; if let target { i.target = target }; return i
        }
        _ = sub("Rumi", [
            item("About Rumi", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Full Disk Access…", #selector(showAccess), "", target: self),
            .separator(),
            item("Hide Rumi", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Rumi", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = sub("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        _ = sub("View", [
            item("Rescan", #selector(rescan), "r", target: self),
            .separator(),
            item("Reload Page", #selector(reloadPage), "r", [.command, .option], target: self),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        _ = sub("Go", [
            item("Back", #selector(goBack), "[", target: self),
            item("Forward", #selector(goForward), "]", target: self),
            item("Enclosing Folder", #selector(goUp), String(UnicodeScalar(NSUpArrowFunctionKey)!), target: self),
        ])
        let win = sub("Window", [
            item("Rumi", #selector(showMainWindow), "0", target: self),
            .separator(),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }
}

// `Rumi --check-trash`: print what Move to Trash would say for some real paths (nothing is moved), then trash a file it
// makes itself and put it back, to prove Undo works.
if CommandLine.arguments.contains("--check-trash") {
    // real places that must be refused or allowed: an app and a piece of it, an app's data folder, the protected folders
    let fm = FileManager.default, support = HOME + "/Library/Application Support"
    var probes = [HOME + "/Downloads", HOME + "/DOCUMENTS", HOME + "/Library/Caches", "/Applications/Safari.app",
                  HOME + "/Library/Mobile Documents", HOME + "/Library/Keychains", HOME + "/Library/Mail"]
    if let app = (try? fm.contentsOfDirectory(atPath: "/Applications"))?.sorted().first(where: { $0.hasSuffix(".app") }) {
        probes += ["/Applications/" + app, "/Applications/" + app + "/Contents/Info.plist"]
    }
    if let data = (try? fm.contentsOfDirectory(atPath: support))?.sorted().first(where: { !$0.hasPrefix(".") }) { probes.append(support + "/" + data) }
    for p in probes where fm.fileExists(atPath: p) {
        let (ok, why) = safeToTrash(p)
        print(ok ? "allowed " : "REFUSED ", p.replacingOccurrences(of: HOME, with: "~"), why.isEmpty ? "" : "— " + why)
    }
    let dir = HOME + "/rumi-test-sec-undo-\(getpid())", t = dir + "/test.txt"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: t, contents: Data("test".utf8))
    print("put back a pair Rumi never made:", putBackJSON([["from": HOME + "/.Trash/test.txt", "to": t]]))
    let r = (trashJSON([t])["results"] as? [[String: Any]] ?? []).first ?? [:]
    print("trash test file:", r)
    if let l = r["trashed"] as? String { print("put back:", putBackJSON([["from": l, "to": t]]), "exists again:", FileManager.default.fileExists(atPath: t)) }
    // three at once, with the same name: one request to Finder, and each one's place in the Trash is still known
    let many = ["a", "b", "c"].map { dir + "/" + $0 + "/test.txt" }
    for m in many { try? fm.createDirectory(atPath: (m as NSString).deletingLastPathComponent, withIntermediateDirectories: true); fm.createFile(atPath: m, contents: Data(m.utf8)) }
    let rs = trashJSON(many)["results"] as? [[String: Any]] ?? []
    print("trash three:", rs.map { "\($0["ok"] ?? "") \((($0["trashed"] as? String ?? "?") as NSString).lastPathComponent)" })
    print("put back three:", putBackJSON(rs.compactMap { r in (r["trashed"] as? String).map { ["from": $0, "to": r["path"] as? String ?? ""] } }),
          "each has its own text again:", many.allSatisfy { (try? String(contentsOfFile: $0, encoding: .utf8)) == $0 })
    // emptying: everything inside goes, a link goes without what it points to
    let bin = dir + "/bin", outside = dir + "/outside.txt"
    try? fm.createDirectory(atPath: bin + "/folder/deep", withIntermediateDirectories: true)
    fm.createFile(atPath: outside, contents: Data("keep".utf8)); fm.createFile(atPath: bin + "/folder/deep/file.txt", contents: Data("x".utf8))
    try? fm.createSymbolicLink(atPath: bin + "/link", withDestinationPath: outside)
    try? fm.createSymbolicLink(atPath: bin + "/folder/link-to-folder", withDestinationPath: dir + "/a")
    let held = FileHandle(forReadingAtPath: bin + "/folder/deep/file.txt")   // a file something still has open
    print("empty a test folder:", removeContents(of: bin) as Any, "left inside:", (try? fm.contentsOfDirectory(atPath: bin)) ?? [],
          "the linked file is still there:", fm.fileExists(atPath: outside), "and the linked folder:", fm.fileExists(atPath: many[0]))
    try? held?.close()
    try? FileManager.default.removeItem(atPath: dir)
    exit(0)
}

// `Rumi --hidden`: measure what fills the disk outside the mapped folders and print it.
if CommandLine.arguments.contains("--hidden") {
    let t0 = Date()
    Hidden.measure()
    var r: [String: Any] = [:]
    repeat { Thread.sleep(forTimeInterval: 0.2); r = Hidden.json() } while r["status"] as? String != "ready"
    print(String(format: "measured in %.1f s · disk %@", Date().timeIntervalSince(t0), diskInfo().description))
    for row in r["rows"] as? [[String: Any]] ?? [] { print(String(format: "  %-42@ %6.2f GB  %@", row["title"] as? String ?? "", Double(row["size"] as? Int64 ?? 0) / 1e9, row["warn"] as? String ?? "")) }
    print("  snapshots:", r["snapshots"] ?? 0, r["newestSnapshot"] ?? "")
    exit(0)
}

// `Rumi --login on|off|status`: start Rumi when you log in (the same switch as Start at Login in the cartridge's menu).
if let i = CommandLine.arguments.firstIndex(of: "--login") {
    let want = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "status"
    if want == "on" || want == "off", let why = QuickSearch.setStartsAtLogin(want == "on") { print("couldn't change it:", why) }
    print("starts at login:", QuickSearch.startsAtLogin ? "yes" : "no")
    exit(0)
}

// `Rumi --mem <pid> [seconds]`: how much memory a running Rumi and its web helpers hold, and how much processor time they use
// while you watch for a while. See Mem.swift.
if let i = CommandLine.arguments.firstIndex(of: "--mem"), CommandLine.arguments.count > i + 1, let pid = pid_t(CommandLine.arguments[i + 1]) {
    Mem.report(pid, watch: CommandLine.arguments.count > i + 2 ? Double(CommandLine.arguments[i + 2]) ?? 0 : 0)
    exit(0)
}

// `Rumi --frees <file or folder>`: what it uses, and what removing it would give back. See Frees.swift.
if let i = CommandLine.arguments.firstIndex(of: "--frees"), CommandLine.arguments.count > i + 1 {
    var st = stat()
    if lstat(CommandLine.arguments[i + 1], &st) == 0, st.st_mode & S_IFMT == S_IFREG { _ = Frees.file(CommandLine.arguments[i + 1], say: true) }   // what the system reports about one file
    let t0 = Date(), s = Frees.measure(CommandLine.arguments[i + 1])
    print(String(format: "uses %lld · frees %lld · %.2f s", s.uses, s.frees, Date().timeIntervalSince(t0)))
    exit(0)
}

// `Rumi --bench`: scan without a window, print totals and timing.
if CommandLine.arguments.contains("--bench") {
    let S = Store.shared
    S.access = "granted"
    let t0 = Date()
    S.startScan()
    while true { Thread.sleep(forTimeInterval: 0.2); S.lock.lock(); let done = S.root != nil && !S.scanning; S.lock.unlock(); if done { break } }
    let secs = Date().timeIntervalSince(t0)
    let top = S.root!
    print(String(format: "scan %.1f s · %d files · %.1f GB · %d folders indexed · %d denied", secs, top.count, Double(top.size) / 1e9, S.index.count, S.denied.count))
    for d in top.dirs { print(String(format: "  %@  %.2f GB  %d files", d.name, Double(d.size) / 1e9, d.count)) }
    let (_, tree) = S.treeJSON(path: HOME, depth: 2)
    let kids = ((tree["node"] as? [String: Any])?["children"] as? [[String: Any]]) ?? []
    for k in kids.prefix(8) { print(String(format: "    %@  %.2f GB  %@", k["name"] as? String ?? "", Double(k["size"] as? Int64 ?? 0) / 1e9, k["cat"] as? String ?? "")) }
    // saved-map round trip: what the next launch will read
    let tw = Date()
    let enc = Snapshot.encode(top: top, roots: S.roots, scannedAt: S.finished, files: top.count, big: S.bigFiles, cats: S.catTotals, denied: S.denied, kinds: S.kindTotals)
    let encT = Date().timeIntervalSince(tw)
    try? enc.write(to: Snapshot.treeURL, options: .atomic)
    S.root = nil
    let tl = Date(); S.loadSaved(); let loadT = Date().timeIntervalSince(tl)
    print(String(format: "saved map: %.1f MB · encode %.0f ms · load %.0f ms · same size %@ · same folders %@", Double(enc.count) / 1e6, encT * 1000, loadT * 1000,
                 S.root?.size == top.size ? "yes" : "NO", S.index.count == Store.buildIndex(top).count ? "yes" : "NO"))
    if CommandLine.arguments.contains("--dupes") {
        for run in 1...2 {
            let td = Date(); findDuplicates(gen: S.generation)
            print(String(format: "duplicates run %d: %.1f s · %d groups", run, Date().timeIntervalSince(td), S.dupes.groups.count))
            let g = S.dupes.groups
            print("  exact \(g.filter { $0["kind"] as? String == "exact" }.count) · similar \(g.filter { $0["kind"] as? String == "similar" }.count) · in projects \(g.filter { $0["project"] as? Bool == true }.count) · any in /Applications \(g.contains { (($0["files"] as? [[String: Any]]) ?? []).contains { ($0["path"] as? String ?? "").hasPrefix("/Applications/") } })")
        }
        Thread.sleep(forTimeInterval: 1)
    }
    let t1 = Date(); let (_, sug) = S.suggestionsJSON()
    print(String(format: "suggestions: %d items in %.2f s", (sug["items"] as? [Any])?.count ?? 0, Date().timeIntervalSince(t1)))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
