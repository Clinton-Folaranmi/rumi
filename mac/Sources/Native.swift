// Rumi — the parts that behave like Finder: Quick Look, right-click menus, and dragging cartridges out.
import AppKit
import WebKit
import Quartz

/// The page's web view. The page tells it which cartridge is under the pointer; a drag that starts on one becomes a
/// real file drag (to Finder, another disk, or the Trash in the Dock), the way Finder's own icons behave.
final class RumiWebView: WKWebView {
    var hoverPath: String?
    private var downPath: String?
    private var downAt = NSPoint.zero
    private let source = DragSource()

    override func mouseDown(with e: NSEvent) {
        downPath = hoverPath; downAt = e.locationInWindow
        super.mouseDown(with: e)
    }
    override func mouseDragged(with e: NSEvent) {
        if let p = downPath, hypot(e.locationInWindow.x - downAt.x, e.locationInWindow.y - downAt.y) > 6 {
            downPath = nil
            if FileManager.default.fileExists(atPath: p) { return startDrag(p, e) }
        }
        super.mouseDragged(with: e)
    }
    override func mouseUp(with e: NSEvent) { downPath = nil; super.mouseUp(with: e) }

    private func startDrag(_ path: String, _ e: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: path) as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: path); icon.size = NSSize(width: 64, height: 64)
        let at = convert(e.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: at.x - 32, y: at.y - 32, width: 64, height: 64), contents: icon)
        source.path = path; source.web = self
        source.canMove = safeToTrash(path).0   // what can't go to the Trash can't be moved out (or dropped on the Dock's Trash) either
        evaluateJavaScript("window.rumiDragStarted && rumiDragStarted()")   // the page ignores the click this drag would end in
        beginDraggingSession(with: [item], event: e, source: source)
    }

    /// WebKit never saw the button come up (the drag took it); give it one so the page isn't stuck mid-press.
    fileprivate func endPress(at screenPoint: NSPoint) {
        guard let w = window, let up = NSEvent.mouseEvent(with: .leftMouseUp, location: w.convertPoint(fromScreen: screenPoint), modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: 0) else { return }
        super.mouseUp(with: up)
    }

    // Quick Look: the panel asks the responder chain who controls it; the web view (first responder) does.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = QuickLook.shared; panel.delegate = QuickLook.shared }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
}

final class DragSource: NSObject, NSDraggingSource {
    var path = ""
    var canMove = false
    weak var web: RumiWebView?

    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor ctx: NSDraggingContext) -> NSDragOperation {
        ctx != .outsideApplication ? [] : canMove ? [.copy, .move, .generic, .delete] : .copy
    }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        web?.endPress(at: p)
        guard operation == .move || operation == .delete || operation == .generic else { return }
        // Finder finishes moves on its own time; once the file has left, take it off the map
        let path = self.path, web = self.web
        for delay in [0.8, 3.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !FileManager.default.fileExists(atPath: path) else { return }
                let S = Store.shared
                S.lock.lock(); let known = S.index[path] != nil || S.index[(path as NSString).deletingLastPathComponent]?.files.contains { $0.name == (path as NSString).lastPathComponent } == true
                if known { S.detach(path) }; S.lock.unlock()
                if known { Snapshot.saveSoon(); web?.evaluateJavaScript("window.rumiMovedAway && rumiMovedAway(\(String(data: jsonData([path]), encoding: .utf8)!)[0])") }
            }
        }
    }
}

final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var urls: [URL] = []

    /// mode: "toggle" (Space), "update" (pointer moved to another cartridge while open), "close". Returns whether it's open.
    func handle(_ paths: [String], mode: String) -> Bool {
        guard let p = QLPreviewPanel.shared() else { return false }
        let next = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        // the panel fades out, so report what was asked for rather than isVisible mid-fade
        switch mode {
        case "close": if p.isVisible { p.orderOut(nil) }; return false
        case "update":
            if p.isVisible, !next.isEmpty, next != urls { urls = next; p.reloadData() }
            return p.isVisible
        default:
            if p.isVisible && (next.isEmpty || next == urls) { p.orderOut(nil); return false }
            guard !next.isEmpty else { return p.isVisible }
            urls = next
            if !p.isVisible { p.orderFront(nil) }
            p.reloadData()
            return true
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }
    // Space and Esc inside the panel close it, like Finder
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 49 || event.keyCode == 53 {
            panel.orderOut(nil)
            (NSApp.delegate as? AppDelegate)?.web.evaluateJavaScript("qlOpen = false")
            return true
        }
        return false
    }
}

/// A native right-click menu built from the page's list of items; replies with the id the person picked (or nothing).
final class ContextMenu: NSObject {
    private var chosen: String?

    static func show(_ items: [[String: Any]], in view: NSView, done: @escaping (String?) -> Void) {
        let cm = ContextMenu(), m = NSMenu()
        m.autoenablesItems = false
        for it in items {
            if it["sep"] as? Bool == true { m.addItem(.separator()); continue }
            let mi = NSMenuItem(title: it["title"] as? String ?? "", action: #selector(pick(_:)), keyEquivalent: it["key"] as? String ?? "")
            mi.keyEquivalentModifierMask = (it["cmd"] as? Bool ?? false) ? .command : []
            mi.representedObject = it["id"] as? String
            mi.isEnabled = it["enabled"] as? Bool ?? true
            mi.target = cm
            m.addItem(mi)
        }
        guard let w = view.window else { return done(nil) }
        let at = view.convert(w.mouseLocationOutsideOfEventStream, from: nil)
        DispatchQueue.main.async {
            m.popUp(positioning: nil, at: at, in: view)   // returns once the menu closes
            done(cm.chosen)
        }
    }
    @objc private func pick(_ s: NSMenuItem) { chosen = s.representedObject as? String }
}
