// Rumi — bytes for the in-app viewer. Photos are drawn at the size the window shows them (a 48 MP original would
// otherwise freeze the page for a second and hold a gigabyte), cached on disk; ones already about that size go out
// as they are. Videos go out in byte ranges, a few MB at a time, never read whole.
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Viewer {
    static let webImage: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg"]
    static let otherImage: Set<String> = ["heic", "heif", "tif", "tiff", "psd", "dng", "cr2", "cr3", "nef", "arw"]
    static let video: [String: String] = ["mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "webm": "video/webm",
                                          "mkv": "video/x-matroska", "avi": "video/x-msvideo"]
    static let chunk = 4 << 20
    static let queue = DispatchQueue(label: "rumi.view", qos: .userInitiated)

    struct Reply { var code: Int; var data: Data; var headers: [String: String] }

    static let cacheDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.clinton.rumi/view", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    /// Keep the drawn copies under ~300 MB: oldest go first. Runs once, a little after launch.
    static func prune() {
        let fm = FileManager.default, keys: [URLResourceKey] = [.contentAccessDateKey, .fileSizeKey]
        guard var files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: keys) else { return }
        files.sort { ((try? $0.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast) }
        var total = 0
        for f in files { total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0; if total > 300 << 20 { try? fm.removeItem(at: f) } }
    }

    /// box: the largest size the page will show, in device pixels (nil = 3200 × 3200).
    static func respond(path raw: String, range: String?, box: (Int, Int)? = nil) -> Reply? {
        guard let p = pathInRoots(raw, follow: true) else { return nil }   // links resolved: none lead out of your folders
        let ext = (p as NSString).pathExtension.lowercased()
        guard webImage.contains(ext) || otherImage.contains(ext) || video[ext] != nil else { return nil }
        var st = stat()
        guard lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_flags & SF_DATALESS_FLAG == 0 else { return nil }   // never pull files down from iCloud
        let size = Int(st.st_size)

        if let type = video[ext] {
            guard let fh = FileHandle(forReadingAtPath: p) else { return nil }
            defer { try? fh.close() }
            var start = 0, end = min(size, chunk) - 1, partial = false
            if let r = range, let m = r.range(of: #"bytes=(\d*)-(\d*)"#, options: .regularExpression) {
                let parts = r[m].dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
                partial = true
                if let a = parts.first ?? nil {
                    start = min(a, size); end = min((parts.count > 1 ? parts[1] : nil) ?? (size - 1), size - 1, start + chunk - 1)   // a huge start can't overflow
                } else if parts.count > 1, let n = parts[1] {   // the last n bytes
                    start = max(0, size - n); end = size - 1
                }
                guard start < size, start <= end else { return Reply(code: 416, data: Data(), headers: ["Content-Range": "bytes */\(size)"]) }
            }
            try? fh.seek(toOffset: UInt64(start))
            let data = (try? fh.read(upToCount: end - start + 1)) ?? Data()
            var h = ["Content-Type": type, "Accept-Ranges": "bytes"]
            if partial || data.count < size { h["Content-Range"] = "bytes \(start)-\(start + data.count - 1)/\(size)" }
            return Reply(code: partial || data.count < size ? 206 : 200, data: data, headers: h)
        }

        let keep = ["Cache-Control": "private, max-age=3600"]
        func whole() -> Reply? {
            guard size < 80 << 20, let d = FileManager.default.contents(atPath: p) else { return nil }
            return Reply(code: 200, data: d, headers: keep.merging(["Content-Type": ext == "svg" ? "image/svg+xml" : ext == "jpg" ? "image/jpeg" : "image/\(ext)"]) { a, _ in a })
        }
        if ext == "gif" || ext == "svg" { return whole() }   // animation and vectors stay as they are
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],   // reads the header only
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int, pw > 0, ph > 0
        else { return webImage.contains(ext) ? whole() : nil }
        let turned = (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        let (w, h) = turned ? (ph, pw) : (pw, ph), (bw, bh) = box ?? (3200, 3200)
        let scale = min(Double(bw) / Double(w), Double(bh) / Double(h), 1)
        if webImage.contains(ext), scale > 0.8 { return whole() }   // about screen size already: send it byte for byte
        let long = Int((Double(max(w, h)) * scale).rounded(.up))
        let alpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
        let mt = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        let key = Thumbs.cacheKey("\(p)|\(mt)|\(long)")
        let file = cacheDir.appendingPathComponent(key + (alpha ? ".png" : ".jpg")), type = alpha ? "image/png" : "image/jpeg"
        if let d = try? Data(contentsOf: file) { return Reply(code: 200, data: d, headers: keep.merging(["Content-Type": type]) { a, _ in a }) }
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                                                     kCGImageSourceShouldCacheImmediately: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: long] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, (alpha ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, alpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        try? (out as Data).write(to: file, options: .atomic)
        return Reply(code: 200, data: out as Data, headers: keep.merging(["Content-Type": type]) { a, _ in a })
    }
}
