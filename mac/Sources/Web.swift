// Rumi — the page runs at rumi://app/. GETs (pages, fonts, /api/*, thumbnails) go through the scheme handler;
// actions (trash, reveal, rescan…) come over the "rumi" message bridge, which replies with JSON.
import AppKit
import WebKit

/// Dev hooks (the page served live from RUMI_WEB_ROOT, the Web Inspector): only with the devTools setting, in a test run
/// (--snapshot), or from scripts/run.sh (--dev).
let DEV_MODE = UserDefaults.standard.bool(forKey: "devTools") || CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--dev")
/// A practice copy (scripts/practice.sh) never moves or deletes anything: the Trash requests are answered "done", so
/// the Bin card can be tried, and tested, as often as you like.
let REVIEW = DEV_MODE && ProcessInfo.processInfo.environment["RUMI_REVIEW"] == "1"

/// New every launch and handed only to the app's own page (main.swift's boot script): every /api/ request must carry it.
let SESSION_TOKEN = UUID().uuidString + UUID().uuidString

let webRoot: URL = {
    if DEV_MODE, let dev = ProcessInfo.processInfo.environment["RUMI_WEB_ROOT"], !dev.isEmpty { return URL(fileURLWithPath: dev, isDirectory: true) }
    return Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)
}()

func jsonData(_ obj: Any) -> Data { (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8) }

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let id = ObjectIdentifier(task)
        let q = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        let path = url.path.isEmpty ? "/" : url.path

        func reply(_ code: Int, _ data: Data, _ type: String, cache: Bool = false) {
            let send = { [self] in
                if stopped.remove(id) != nil { return }
                let headers = ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": cache ? "private, max-age=86400" : "no-store"]
                task.didReceive(HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!)
                task.didReceive(data)
                task.didFinish()
            }
            Thread.isMainThread ? send() : DispatchQueue.main.async(execute: send)
        }
        func json(_ r: (Int, [String: Any])) { reply(r.0, jsonData(r.1), "application/json") }

        // a web page in the viewer and everything it loads: its own origin, sandboxed, read-only, inside your folders
        if url.host == "files" {
            let p = url.path
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                guard let (data, type) = Pages.file(p) else { return reply(404, Data(), "text/plain") }
                let send = { [self] in
                    if stopped.remove(id) != nil { return }
                    let h = ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": "no-store",
                             "Content-Security-Policy": "sandbox allow-scripts allow-forms"]
                    task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: h)!)
                    task.didReceive(data); task.didFinish()
                }
                DispatchQueue.main.async(execute: send)
            }
            return
        }
        // the app's data is only for the app's own page: it sends this launch's token (X-Token, or ?t= on pictures and
        // video, which can't send headers). A page in the viewer never has it. WebKit sends no Referer with pictures and
        // video, so a missing one is fine; one from anywhere but the app is refused.
        if path.hasPrefix("/api/") || path.hasPrefix("/native/") {
            let token = task.request.value(forHTTPHeaderField: "X-Token") ?? q["t"], referer = task.request.value(forHTTPHeaderField: "Referer") ?? ""
            guard token == SESSION_TOKEN, referer.isEmpty || referer.hasPrefix("rumi://app/") else { return reply(403, Data(), "text/plain") }
        }

        // static files
        let pages = ["/": "index.html", "/index.html": "index.html", "/styles.css": "styles.css", "/app.css": "app.css", "/rumi.js": "rumi.js",
                     "/base.js": "base.js", "/find.js": "find.js", "/quick": "quick.html", "/design-system": "design-system.html"]
        if let file = pages[path] ?? (path.hasPrefix("/fonts/") && !path.contains("..") ? String(path.dropFirst()) : nil) {
            let f = webRoot.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: f) else { return reply(404, Data(), "text/plain") }
            let type = file.hasSuffix(".html") ? "text/html; charset=utf-8" : file.hasSuffix(".css") ? "text/css; charset=utf-8" : file.hasSuffix(".js") ? "text/javascript; charset=utf-8" : "font/woff2"
            return reply(200, data, type, cache: file.hasSuffix(".woff2"))
        }

        // the viewer: a photo or video at full size. Videos stream in pieces (WebKit asks with Range) so seeking is instant.
        if path == "/api/view" {
            let p = q["path"] ?? ""
            let range = task.request.value(forHTTPHeaderField: "Range")
            let box = Int(q["bw"] ?? "").flatMap { w in Int(q["bh"] ?? "").map { (min(max(w, 256), 8192), min(max($0, 256), 8192)) } }
            // pictures are drawn one at a time (two 48 MP decodes at once would double the memory); video pieces go straight out
            let isVideo = Viewer.video[(p as NSString).pathExtension.lowercased()] != nil
            (isVideo ? DispatchQueue.global(qos: .userInitiated) : Viewer.queue).async { [self] in
                guard let r = Viewer.respond(path: p, range: range, box: box) else { return reply(404, Data(), "text/plain") }
                let send = { [self] in
                    if stopped.remove(id) != nil { return }
                    var h = r.headers; h["Content-Length"] = String(r.data.count); h["Cache-Control"] = h["Cache-Control"] ?? "no-store"
                    task.didReceive(HTTPURLResponse(url: url, statusCode: r.code, httpVersion: "HTTP/1.1", headerFields: h)!)
                    task.didReceive(r.data); task.didFinish()
                }
                DispatchQueue.main.async(execute: send)
            }
            return
        }

        let S = Store.shared
        DispatchQueue.global(qos: .userInitiated).async {
            switch path {
            case "/api/status": json((200, S.statusJSON()))
            case "/api/tree": json(S.treeJSON(path: q["path"] ?? "", depth: Int(q["depth"] ?? "2") ?? 2))
            case "/api/overview": json(S.overviewJSON())
            case "/api/suggestions": json(S.suggestionsJSON())
            case "/api/dupes": json(S.dupesJSON())
            case "/api/hidden": json((200, Hidden.json()))
            case "/api/changed": json(Changes.json(path: q["path"] ?? ""))
            case "/api/kinds": json((200, Search.kindsJSON()))
            case "/api/text": json(Pages.text(q["path"] ?? ""))
            case "/api/filter": json(Filter.json(path: q["path"] ?? "", mask: UInt32(q["mask"] ?? "0") ?? 0, cat: q["cat"] ?? "", days: Int(q["days"] ?? "0") ?? 0))
            case "/api/ages": json(Filter.agesJSON(path: q["path"] ?? "", mask: UInt32(q["mask"] ?? "0") ?? 0, cat: q["cat"] ?? "",
                                                   days: (q["days"] ?? "").split(separator: ",").compactMap { Int($0) }.filter { $0 > 0 }))
            case "/api/search":
                // typing sends a query per pause; ones overtaken by a newer query are skipped
                let text = (q["q"] ?? "").trimmingCharacters(in: .whitespaces), src = q["src"] ?? "index"
                if text.isEmpty { return json((200, ["q": text, "results": Search.biggest()])) }
                Search.setLatest(text)
                Search.queue.async {
                    guard Search.isLatest(text) else { return json((200, ["q": text, "stale": true, "results": []])) }
                    json((200, ["q": text, "src": src, "results": src == "spotlight" ? Search.spotlight(text) : Search.index(text)]))
                }
            case "/api/thumb":
                // the link at the end isn't followed, so /Applications/Safari.app (a link into the system) keeps its icon
                guard let p = pathInRoots(q["path"] ?? ""), THUMB_EXT.contains((p as NSString).pathExtension.lowercased()) || p.hasSuffix(".app") else {
                    return reply(404, Data(), "text/plain")
                }
                let size = max(16, min(400, Int(q["s"] ?? "400") ?? 400))
                Thumbs.png(for: p, size: size) { data in
                    if let d = data { reply(200, d, "image/png", cache: true) } else { reply(404, Data(), "text/plain", cache: true) }
                }
            default: json((404, ["error": "nope"]))
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}

final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        // only the app itself may act: never a web page shown in the viewer
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.host == "app" else { return replyHandler(nil, "not allowed") }
        guard let msg = message.body as? [String: Any], let path = msg["path"] as? String else { return replyHandler(nil, "bad message") }
        let body = msg["body"] as? [String: Any] ?? [:]
        let done: ([String: Any]) -> Void = { obj in DispatchQueue.main.async { replyHandler(obj, nil) } }
        let S = Store.shared
        switch path {
        case "/api/trash":
            let paths = body["paths"] as? [String] ?? []
            if REVIEW { return done(["results": paths.map { ["path": $0, "ok": true, "error": "", "trashed": "/practice"] }]) }
            DispatchQueue.global(qos: .userInitiated).async { done(trashJSON(paths)) }
        case "/api/reveal":
            // in a new Finder window on the screen this was asked from (the panel's, or the main window's)
            done(["ok": !showInFinder(body["path"] as? String ?? "", select: true, on: message.webView?.window?.screen).isEmpty])
        case "/api/frees":
            // what removing this would really give back (shared space isn't counted). Asked for the Clean up list, quietly
            // ("low"), and for what's picked, right away. A big folder takes a few seconds
            guard let p = pathInRoots(body["path"] as? String ?? "") else { return done(["error": "outside the scanned folders"]) }
            let size = (body["size"] as? NSNumber)?.int64Value ?? 0, low = body["low"] as? Bool ?? false
            DispatchQueue.global(qos: low ? .utility : .userInitiated).async {
                let s = Frees.of(p, size: size, workers: low ? 2 : 4)
                done(["uses": s.uses, "frees": s.frees])
            }
        case "/api/put-back":
            let items = (body["items"] as? [[String: Any]] ?? []).map { $0.compactMapValues { $0 as? String } }
            if REVIEW { return done(["ok": true, "back": items.count, "error": ""]) }
            DispatchQueue.global(qos: .userInitiated).async { done(putBackJSON(items)) }
        case "/native/title":
            if let t = body["title"] as? String { NSApp.mainWindow?.title = t.isEmpty ? "Rumi" : t; NSApp.windows.first?.title = t.isEmpty ? "Rumi" : t }
            done(["ok": true])
        case "/api/empty-trash":
            if REVIEW { return done(["ok": true, "error": ""]) }
            DispatchQueue.global(qos: .userInitiated).async { done(emptyTrashJSON()) }
        case "/api/rescan":
            S.startScan(); done(["ok": true])
        case "/native/open-privacy":
            Access.openSettings(); done(["ok": true])
        case "/native/skip-access":
            Access.skip(); done(["ok": true])
        case "/native/hover":
            (message.webView as? RumiWebView)?.hoverPath = body["path"] as? String
            done(["ok": true])
        case "/native/write" where CommandLine.arguments.contains("--snapshot"):
            // test runs only: save text a script collected
            if let out = body["out"] as? String, let text = body["text"] as? String { try? text.write(toFile: out, atomically: true, encoding: .utf8) }
            done(["ok": true])
        case "/native/snap" where CommandLine.arguments.contains("--snapshot"):
            // test runs only: save what the window shows right now (lets a script capture animation frames)
            guard let wv = message.webView, let out = body["out"] as? String else { return done(["ok": false]) }
            var cfg: WKSnapshotConfiguration? = nil
            if let r = body["rect"] as? [Double], r.count == 4 { cfg = WKSnapshotConfiguration(); cfg!.rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }
            wv.takeSnapshot(with: cfg) { img, _ in
                writePNG(img, to: out)
                done(["ok": true])
            }
        case "/native/viewer":
            S.viewerOpen = body["open"] as? Bool ?? false
            done(["ok": true])
        case "/native/quicklook":
            done(["open": QuickLook.shared.handle(body["paths"] as? [String] ?? [], mode: body["mode"] as? String ?? "toggle")])
        case "/native/menu":
            guard let v = message.webView else { return done(["chosen": NSNull()]) }
            ContextMenu.show(body["items"] as? [[String: Any]] ?? [], in: v) { done(["chosen": $0 ?? NSNull()]) }
        case "/native/open":
            let p = body["path"] as? String ?? ""
            guard FileManager.default.fileExists(atPath: p) else { return done(["ok": false]) }   // moved or deleted since it was listed
            if let p = pathInRoots(p) {
                let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if v?.isDirectory == true && v?.isPackage != true { showInFinder(p, select: false, on: message.webView?.window?.screen) }   // a folder: a Finder window here
                else { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
            }
            done(["ok": true])
        case "/native/copy":   // a how-to's command, to paste into Terminal
            NSPasteboard.general.clearContents()
            done(["ok": NSPasteboard.general.setString(body["text"] as? String ?? "", forType: .string)])
        case "/native/quick-close":   // the menu-bar search panel: Esc, or a result was opened
            QuickSearch.shared.hide(); done(["ok": true])
        case "/native/show-in-rumi":   // the panel's ⌥↵: bring the main window forward and show this on the map
            QuickSearch.shared.hide()
            (NSApp.delegate as? AppDelegate)?.showOnMap(body["item"] as? [String: Any] ?? [:])
            done(["ok": true])
        case "/native/mem" where CommandLine.arguments.contains("--snapshot"):   // test runs: what Rumi holds right now
            DispatchQueue.global().async { done(Mem.snapshot(getpid())) }
        case "/native/test-window" where CommandLine.arguments.contains("--snapshot"):   // test runs: close or reopen the main window
            if body["show"] as? Bool == true { NSApp.windows.first { !($0 is NSPanel) }?.orderFront(nil) } else { NSApp.windows.first { !($0 is NSPanel) }?.orderOut(nil) }
            done(["ok": true])
        case "/native/test-finder" where CommandLine.arguments.contains("--snapshot"):   // test runs: where a Show in Finder window is asked to go
            done(["rect": showInFinder(body["path"] as? String ?? "", select: true, on: NSScreen.main)])
        case "/native/test-unload" where CommandLine.arguments.contains("--snapshot"):
            // test runs: let the map's page go as a closed window would, then print what Rumi holds once that has settled
            guard let d = NSApp.delegate as? AppDelegate else { return done(["ok": false]) }
            d.holdUntil = Date().addingTimeInterval(24)
            done(["ok": true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { d.window.orderOut(nil); d.unloadPage() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {   // then what the idle check does after a while
                QuickSearch.shared.releasePanel()
                for _ in 0..<40 where !Store.shared.unload() { Thread.sleep(forTimeInterval: 0.1) }
                print("map let go:", Store.shared.root == nil); fflush(stdout)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                let m = Mem.snapshot(getpid())
                print("after the page is let go:", Int((m["totalMB"] as? Double ?? 0).rounded()), "MB ·", (m["parts"] as? [[String: Any]] ?? []).map { "\($0["name"] as? String ?? "") \($0["mb"] ?? 0)" }.joined(separator: " · "))
                fflush(stdout)
                // then ask for something on the map, as the search panel's ⌥↵ does: the window's page has to come back first
                let t0 = Date(); Store.shared.ensureLoaded()
                while Store.shared.root == nil && Date().timeIntervalSince(t0) < 20 { Thread.sleep(forTimeInterval: 0.02) }
                print(String(format: "map read back in %.2f s", Date().timeIntervalSince(t0))); fflush(stdout)
                DispatchQueue.main.async {
                    d.showOnMap(["path": HOME + "/Downloads", "name": "Downloads", "type": "dir", "cat": "other", "size": 1, "pkg": false])
                    d.window.setFrameOrigin(NSPoint(x: -6000, y: 0))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        d.web?.evaluateJavaScript("JSON.stringify({ cartridges: document.querySelectorAll('#map .b').length, atHome: current === HOME, flashed: !!document.querySelector('#map .b.found') })") { r, _ in
                            print("after coming back:", r ?? "no page"); fflush(stdout)
                        }
                    }
                }
            }
        case "/native/test-timing" where CommandLine.arguments.contains("--snapshot"):   // test runs: time search and the window coming back
            guard let d = NSApp.delegate as? AppDelegate else { return done(["ok": false]) }
            d.holdUntil = Date().addingTimeInterval(120)
            done(["ok": true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { d.runTiming() }
        case "/native/quick-live" where CommandLine.arguments.contains("--snapshot"):
            QuickSearch.shared.liveTest(done: done)
        case "/native/quick-test" where CommandLine.arguments.contains("--snapshot"):
            QuickSearch.shared.test(query: body["q"] as? String ?? "", out: body["out"] as? String ?? "/tmp/rumi-quick.png", done: done)
        case "/native/ping":   // the --snapshot self-check: the bridge answers
            done(["ok": true])
        default:
            replyHandler(nil, "unknown action \(path)")
        }
    }
}
