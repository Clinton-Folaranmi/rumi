// Rumi — thumbnails: Quick Look for files, the real icon for apps. Cached on disk, at most 4 made at once.
import AppKit
import QuickLookThumbnailing
import CryptoKit

let THUMB_EXT: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "psd", "dng", "cr2", "cr3",
                              "nef", "arw", "bmp", "svg", "mp4", "mov", "m4v", "mkv", "avi", "webm", "pdf", "key", "pages", "numbers", "ai", "sketch"]

enum Thumbs {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("com.clinton.rumi/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static let gate = DispatchSemaphore(value: 4)
    static let queue = DispatchQueue(label: "rumi.thumbs", qos: .userInitiated, attributes: .concurrent)

    /// A cache file name for a drawn copy (thumbnails here, viewer pictures in Viewer.swift).
    static func cacheKey(_ s: String) -> String { hexString(Insecure.SHA1.hash(data: Data(s.utf8))) }

    /// PNG data for a path, or nil if there's no preview.
    static func png(for path: String, size: Int, done: @escaping (Data?) -> Void) {
        queue.async {
            var st = stat()
            guard lstat(path, &st) == 0, st.st_flags & SF_DATALESS_FLAG == 0 else { return done(nil) }   // never download cloud files
            let mt = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            let key = cacheKey("\(path)|\(mt)|\(size)")
            let out = dir.appendingPathComponent(key + ".png"), miss = dir.appendingPathComponent(key + ".none")
            if let d = try? Data(contentsOf: out) { return done(d) }
            if FileManager.default.fileExists(atPath: miss.path) { return done(nil) }
            gate.wait()
            let finish: (Data?) -> Void = { data in
                gate.signal()
                if let data = data { try? data.write(to: out, options: .atomic) } else { FileManager.default.createFile(atPath: miss.path, contents: nil) }
                done(data)
            }
            if path.hasSuffix(".app") {
                DispatchQueue.main.async {
                    let icon = NSWorkspace.shared.icon(forFile: path)
                    let px = min(256, size)
                    finish(render(icon, px: px))
                }
                return
            }
            let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: size, height: size), scale: 1, representationTypes: .thumbnail)
            var called = false
            let lock = NSLock()
            let once: (Data?) -> Void = { d in lock.lock(); defer { lock.unlock() }; if !called { called = true; finish(d) } }
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                guard let cg = rep?.cgImage else { return once(nil) }
                once(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            }
            queue.asyncAfter(deadline: .now() + 15) { once(nil) }   // a stuck generator must not hold a slot forever
        }
    }

    private static func render(_ img: NSImage, px: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
