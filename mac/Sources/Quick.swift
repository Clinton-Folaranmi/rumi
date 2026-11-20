// Rumi — search from anywhere. A cartridge in the menu bar opens the search panel over whatever you're doing.
// The panel is a small borderless window that takes the keyboard without bringing Rumi (or its main window) forward,
// and goes away when you click elsewhere or press Esc. Its page is web/quick.html, the same search as ⌘F in the app.
import AppKit
import WebKit
import Carbon.HIToolbox
import ServiceManagement

/// A borderless panel that can still take typing.
final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class QuickSearch: NSObject, NSWindowDelegate, WKNavigationDelegate {
    static let shared = QuickSearch()
    static let size = NSSize(width: 600, height: 460)

    /// Set by the app: a web view configuration with the app's scheme handler, bridge and launch token.
    var makeConfig: (() -> WKWebViewConfiguration)?
    /// Set by the app: bring the main window forward.
    var showMain: (() -> Void)?

    private var item: NSStatusItem?
    private var panel: QuickPanel?
    private var web: WKWebView?

    // MARK: the menu-bar cartridge

    func install() {
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        it.button?.image = QuickSearch.icon()
        it.button?.setAccessibilityLabel("Search with Rumi")
        it.button?.target = self
        it.button?.action = #selector(clicked(_:))
        it.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item = it
    }

    /// Rumi's cartridge as a menu-bar glyph: shell, label window with two eyes, connector notches. A template image, so
    /// macOS colours it for a light or dark menu bar.
    static func icon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let shell = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 1.5, width: 13, height: 15), xRadius: 3, yRadius: 3)
            shell.append(NSBezierPath(roundedRect: NSRect(x: 4.5, y: 7.2, width: 9, height: 6.8), xRadius: 1.3, yRadius: 1.3))
            for x in [5.6, 8.2, 10.8] { shell.append(NSBezierPath(rect: NSRect(x: x, y: 3.2, width: 1.6, height: 1.9))) }
            shell.windingRule = .evenOdd
            shell.fill()
            NSBezierPath(ovalIn: NSRect(x: 6.5, y: 9.5, width: 1.8, height: 2.3)).fill()
            NSBezierPath(ovalIn: NSRect(x: 9.7, y: 9.5, width: 1.8, height: 2.3)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    @objc private func clicked(_ sender: Any?) {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true { showMenu() } else { toggle() }
    }

    private func showMenu() {
        hide()
        let m = NSMenu()
        let find = m.addItem(withTitle: "Search", action: #selector(searchFromMenu), keyEquivalent: " ")
        find.keyEquivalentModifierMask = [.control, .option]; find.target = self
        let open = m.addItem(withTitle: "Open Rumi", action: #selector(openMain), keyEquivalent: "")
        open.target = self
        m.addItem(.separator())
        let login = m.addItem(withTitle: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = QuickSearch.startsAtLogin ? .on : .off
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Rumi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item?.menu = m
        item?.button?.performClick(nil)
        item?.menu = nil
    }

    @objc private func openMain() { showMain?() }
    @objc private func searchFromMenu() { show() }

    // MARK: the shortcut: Control-Option-Space opens search from any app

    private var hotKey: EventHotKeyRef?
    func registerShortcut() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { QuickSearch.shared.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5255_4D49), id: 1)   // "RUMI"
        let err = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if err != noErr { NSLog("Rumi: couldn't take Control-Option-Space as the search shortcut (\(err))") }
    }

    // MARK: start at login

    static var startsAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    /// Returns nil when it worked, or why it didn't.
    @discardableResult static func setStartsAtLogin(_ on: Bool) -> String? {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; return nil }
        catch { return error.localizedDescription }
    }
    @objc private func toggleLogin() {
        if let why = QuickSearch.setStartsAtLogin(!QuickSearch.startsAtLogin) {
            let a = NSAlert(); a.messageText = "Couldn't change Start at Login"; a.informativeText = why; a.runModal()
        }
    }

    // MARK: the panel

    func toggle() { if panel?.isVisible == true { hide() } else { show() } }

    func hide() { panel?.orderOut(nil); lastUsed = Date() }

    /// When the panel was last opened or closed, and whether it's open now (the app lets memory go when it's been a while).
    private(set) var lastUsed = Date()
    var isOpen: Bool { panel?.isVisible == true }
    /// Let the panel's page go; it's built again the next time search opens.
    func releasePanel() {
        guard !isOpen, panel != nil else { return }
        panel?.contentView = nil
        panel = nil; web = nil
    }

    func show() {
        lastUsed = Date()
        Store.shared.ensureLoaded()   // the map may have been let go; it reads back while the panel opens
        if panel == nil { build() }
        guard let panel, let web else { return }
        // under the cartridge, centred on it, kept inside the screen
        let size = QuickSearch.size
        var origin = NSPoint(x: 120, y: 120)
        if let b = item?.button, let w = b.window {
            let r = w.convertToScreen(b.convert(b.bounds, to: nil))
            let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            origin = NSPoint(x: min(max(r.midX - size.width / 2, vis.minX + 10), vis.maxX - size.width - 10), y: r.minY - 8 - size.height)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(web)
        web.evaluateJavaScript("window.focusQuick && focusQuick()")
        Live.bringCurrent()   // sizes and big files in the results follow what's on disk now
    }

    private func build() {
        guard let cfg = makeConfig?() else { return }
        let size = QuickSearch.size
        let p = QuickPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.delegate = self
        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.cornerRadius = 16
        box.layer?.masksToBounds = true
        box.layer?.backgroundColor = PAPER.cgColor
        let wv = WKWebView(frame: box.bounds, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.isInspectable = DEV_MODE
        wv.navigationDelegate = self
        box.addSubview(wv)
        p.contentView = box
        wv.load(URLRequest(url: URL(string: "rumi://app/quick")!))
        panel = p
        web = wv
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    /// The panel only ever shows the app's own search page.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let u = action.request.url
        decisionHandler(u?.scheme == "rumi" && u?.host == "app" ? .allow : .cancel)
    }

    /// Test runs only (--snapshot): put the cartridge in the menu bar, open the real panel for a moment and report where it
    /// landed and whether typing would go to the search field. Then take both away again.
    func liveTest(done: @escaping ([String: Any]) -> Void) {
        if item == nil { install() }
        NSApp.deactivate()   // as in real use: some other app is in front when the cartridge is clicked
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [self] in
                guard let panel, let web, let b = item?.button, let w = b.window else { return done(["ok": false]) }
                let br = w.convertToScreen(b.convert(b.bounds, to: nil)), pf = panel.frame, vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? .zero
                var info: [String: Any] = ["ok": true, "visible": panel.isVisible, "key": panel.isKeyWindow, "appActive": NSApp.isActive,
                                           "gapBelowIcon": Double(br.minY - pf.maxY), "insideScreen": vis.insetBy(dx: -1, dy: -1).contains(pf),
                                           "centredOnIcon": abs(pf.midX - br.midX) < 2, "size": [Double(pf.width), Double(pf.height)],
                                           "iconWidth": Double(br.width), "responderIsWeb": panel.firstResponder === web || (panel.firstResponder as? NSView)?.isDescendant(of: web) == true]
                web.evaluateJavaScript("document.activeElement && document.activeElement.id") { r, _ in
                    info["focused"] = r as? String ?? "none"
                    self.hide()
                    info["hiddenAfter"] = !panel.isVisible
                    if let it = self.item { NSStatusBar.system.removeStatusItem(it); self.item = nil }
                    done(info)
                }
            }
        }
    }

    /// Test runs only (--snapshot): open the panel off screen as a click on the cartridge would and time it, in milliseconds:
    /// "page" until its search field can take typing, "list" until the list under it is drawn, "map" until the map of the
    /// disk is in memory (sizes and folders in results need it).
    func timeOpen(done: @escaping ([String: Int]) -> Void) {
        let t0 = Date()
        lastUsed = Date()
        Store.shared.ensureLoaded()
        if panel == nil { build() }
        guard let panel, let web else { return done([:]) }
        panel.setFrame(NSRect(origin: NSPoint(x: -6000, y: 0), size: QuickSearch.size), display: true)
        panel.orderFront(nil)
        // a panel that was kept: empty the list, then ask it to open as show() does. A new one opens by itself once loaded.
        web.evaluateJavaScript("if (window.focusQuick) { document.getElementById('f-list').innerHTML = ''; focusQuick(); }")
        var out: [String: Int] = [:]
        func poll() {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if out["map"] == nil, Store.shared.root != nil { out["map"] = ms }
            web.evaluateJavaScript("typeof findRun !== 'function' ? 0 : document.querySelectorAll('#f-list .fr').length ? 2 : 1") { r, _ in
                let state = r as? Int ?? 0
                if state >= 1, out["page"] == nil { out["page"] = ms }
                if state >= 2, out["list"] == nil { out["list"] = ms }
                if (out["list"] != nil && out["map"] != nil) || ms > 15000 { panel.orderOut(nil); return done(out) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { poll() }
            }
        }
        poll()
    }

    /// Test runs only (--snapshot): build the panel off screen, type a query, save a picture of it and report what it shows.
    func test(query: String, out: String, done: @escaping ([String: Any]) -> Void) {
        if panel == nil { build() }
        guard let panel, let web else { return done(["ok": false]) }
        panel.setFrame(NSRect(origin: NSPoint(x: -6000, y: 0), size: QuickSearch.size), display: true)
        panel.orderFront(nil)
        let q = String(data: jsonData([query]), encoding: .utf8) ?? "[\"\"]"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            web.callAsyncJavaScript("const q = \(q)[0]; document.getElementById('f-q').value = q; await findRun(); await new Promise(r => setTimeout(r, 1800)); return { rows: document.querySelectorAll('.fr').length, first: F.items.slice(0, 3).map(k => k.type), found: document.getElementById('f-n').textContent, focusFn: typeof focusQuick };", in: nil, in: .page) { res in
                var info = (try? res.get()) as? [String: Any] ?? ["error": "\(res)"]
                web.takeSnapshot(with: nil) { img, _ in
                    writePNG(img, to: out)
                    info["ok"] = true
                    panel.orderOut(nil)
                    done(info)
                }
            }
        }
    }
}
