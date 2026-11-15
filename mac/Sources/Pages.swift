// Rumi — web pages and text in the viewer.
// A web page is shown live, from its own folder, at rumi://files/<path> so its pictures, styles and scripts load
// the way they would in a browser. That's a different origin from the app (rumi://app), the frame is sandboxed
// (scripts run, but in an origin of their own), and the app refuses API calls that come from it, so a page can
// never read your file list or reach the Trash. It can load files from its own folder only (just that folder, no deeper, for a page sitting right in Home). Text and code come as
// plain text for the Code view.
import Foundation
import UniformTypeIdentifiers

enum Pages {
    static let maxFile = 64 << 20           // anything a page loads (pictures, fonts, scripts) up to 64 MB
    static let maxText = 1 << 20            // the Code view shows the first 1 MB

    private static let lock = NSLock()
    private static var folder: String?      // the folder of the page the viewer showed last, links resolved

    /// The app put a page in the viewer (main.swift sees the app's own frame start that load): it may load from its folder.
    static func opened(_ raw: String) {
        let f = pathInRoots((raw as NSString).deletingLastPathComponent, follow: true)
        lock.lock(); folder = f; lock.unlock()
    }

    /// A file a page asked for. nil = not allowed (outside the page's folder, a cloud placeholder, a folder, too big).
    static func file(_ raw: String) -> (Data, String)? {
        lock.lock(); let base = folder; lock.unlock()
        var st = stat()
        guard let base, let p = pathInRoots(raw, follow: true), p.hasPrefix(base + "/"),   // links resolved first: none lead out
              // a page sitting right in Home (or Applications) gets that folder's own files, not everything below it
              !isScannedRoot(base) || (p as NSString).deletingLastPathComponent == base,
              lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_flags & SF_DATALESS_FLAG == 0, st.st_size <= maxFile,
              let fh = FileHandle(forReadingAtPath: p) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: maxFile + 1), data.count <= maxFile else { return nil }   // it may have grown since
        let ext = (p as NSString).pathExtension.lowercased()
        var type = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        if ext == "html" || ext == "htm" { type = "text/html" }   // no charset: the page's own <meta charset> decides
        return (data, type)
    }

    /// The first megabyte of a text file, or why it can't be shown.
    static func text(_ raw: String) -> (Int, [String: Any]) {
        var st = stat()
        guard let p = pathInRoots(raw, follow: true) else { return lstat(raw, &st) == 0 ? (403, ["error": "outside"]) : (404, ["error": "missing"]) }
        guard lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return (404, ["error": "missing"]) }
        guard st.st_flags & SF_DATALESS_FLAG == 0 else { return (409, ["error": "in iCloud"]) }
        guard let fh = FileHandle(forReadingAtPath: p) else { return (403, ["error": "unreadable"]) }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: maxText)) ?? Data()
        if data.prefix(8192).contains(0) { return (415, ["error": "binary"]) }
        var s = String(decoding: data, as: UTF8.self)
        let cut = Int64(data.count) < Int64(st.st_size)
        if cut, let nl = s.lastIndex(of: "\n") { s = String(s[..<nl]) }   // end on a whole line
        return (200, ["text": s, "truncated": cut, "size": Int64(st.st_size)])
    }
}
