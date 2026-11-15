// Draws Rumi's app icon: three cartridges fanned on warm paper, the pink one in front. Full-bleed so macOS applies its own mask.
import AppKit

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a) }
func mix(_ h: UInt32, _ w: UInt32, _ t: CGFloat) -> CGColor {
    let a = [h >> 16 & 255, h >> 8 & 255, h & 255].map(CGFloat.init), b = [w >> 16 & 255, w >> 8 & 255, w & 255].map(CGFloat.init)
    return CGColor(srgbRed: (a[0] + (b[0] - a[0]) * t) / 255, green: (a[1] + (b[1] - a[1]) * t) / 255, blue: (a[2] + (b[2] - a[2]) * t) / 255, alpha: 1)
}
func shell(_ r: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + bottom, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - bottom, y: r.minY)); p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + bottom), control: CGPoint(x: r.maxX, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - top)); p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY)); p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - top), control: CGPoint(x: r.minX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + bottom)); p.addQuadCurve(to: CGPoint(x: r.minX + bottom, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
    p.closeSubpath(); return p
}

// paper
ctx.drawLinearGradient(CGGradient(colorsSpace: cs, colors: [rgb(0xf7f4ee), rgb(0xebe5da)] as CFArray, locations: [0, 1])!,
                       start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

func cartridge(color: UInt32, center: CGPoint, angle: CGFloat, w: CGFloat, h: CGFloat, front: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y); ctx.rotate(by: angle * .pi / 180)
    let r = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    let body = shell(r, top: w * 0.11, bottom: w * 0.05)
    // soft contact shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -h * 0.035), blur: h * 0.07, color: rgb(0x3a2f20, front ? 0.28 : 0.18))
    ctx.addPath(body); ctx.setFillColor(rgb(color)); ctx.fillPath()
    ctx.restoreGState()
    // plastic shading: lighter top, darker bottom lip
    ctx.saveGState(); ctx.addPath(body); ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: cs, colors: [mix(color, 0xffffff, 0.16), rgb(color), mix(color, 0x000000, 0.10)] as CFArray, locations: [0, 0.45, 1])!,
                           start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
    ctx.setFillColor(rgb(0xffffff, 0.22)); ctx.fill(CGRect(x: r.minX, y: r.minY, width: w * 0.035, height: h))
    ctx.setFillColor(rgb(0x000000, 0.07)); ctx.fill(CGRect(x: r.maxX - w * 0.035, y: r.minY, width: w * 0.035, height: h))
    // grip ridges at the top
    for i in 0..<4 { ctx.setFillColor(rgb(0x000000, 0.12)); ctx.fill(CGRect(x: -w * 0.16, y: r.maxY - h * 0.045 - CGFloat(i) * h * 0.016, width: w * 0.32, height: h * 0.006)) }
    // connector edge with contacts
    let slot = CGRect(x: r.minX + w * 0.1, y: r.minY + h * 0.022, width: w * 0.8, height: h * 0.05)
    ctx.setFillColor(rgb(0x000000, 0.12)); ctx.addPath(CGPath(roundedRect: slot, cornerWidth: h * 0.012, cornerHeight: h * 0.012, transform: nil)); ctx.fillPath()
    var x = slot.minX + w * 0.035
    while x < slot.maxX - w * 0.04 { ctx.setFillColor(rgb(0x000000, 0.22)); ctx.fill(CGRect(x: x, y: slot.minY + h * 0.01, width: w * 0.022, height: slot.height - h * 0.02)); x += w * 0.05 }
    // printed label
    let label = CGRect(x: r.minX + w * 0.1, y: r.minY + h * 0.24, width: w * 0.8, height: h * 0.62)
    let lp = CGPath(roundedRect: label, cornerWidth: w * 0.035, cornerHeight: w * 0.035, transform: nil)
    ctx.addPath(lp); ctx.setFillColor(mix(color, 0xfffdf8, 0.82)); ctx.fillPath()
    ctx.addPath(lp); ctx.clip()
    for (i, t) in [0.0, 1.0].enumerated() {
        _ = t
        ctx.setFillColor(rgb(color)); ctx.fill(CGRect(x: label.minX, y: label.minY + label.height * (0.1 + CGFloat(i) * 0.11), width: label.width, height: label.height * 0.06))
    }
    if front {
        // a big dot "loaded" mark on the front cartridge
        ctx.setFillColor(rgb(color)); ctx.fillEllipse(in: CGRect(x: label.minX + label.width * 0.12, y: label.maxY - label.height * 0.36, width: label.width * 0.22, height: label.width * 0.22))
        ctx.setFillColor(rgb(0x18181b, 0.82)); ctx.fill(CGRect(x: label.minX + label.width * 0.42, y: label.maxY - label.height * 0.235, width: label.width * 0.44, height: label.height * 0.055))
        ctx.setFillColor(rgb(0x18181b, 0.35)); ctx.fill(CGRect(x: label.minX + label.width * 0.42, y: label.maxY - label.height * 0.33, width: label.width * 0.3, height: label.height * 0.04))
    }
    ctx.restoreGState()
    ctx.restoreGState()
}

cartridge(color: 0xf3c14d, center: CGPoint(x: S * 0.33, y: S * 0.53), angle: 13, w: S * 0.36, h: S * 0.46, front: false)
cartridge(color: 0x8a7fe6, center: CGPoint(x: S * 0.67, y: S * 0.53), angle: -13, w: S * 0.36, h: S * 0.46, front: false)
cartridge(color: 0xec4f7c, center: CGPoint(x: S * 0.5, y: S * 0.46), angle: 0, w: S * 0.42, h: S * 0.54, front: true)

let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
