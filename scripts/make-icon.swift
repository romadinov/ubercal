import AppKit

// Draws the Ubercal icon in Uberdoer's style: dark navy squircle, glossy stacked blue cards,
// the top card a calendar page with one glowing cyan-green day. Usage: make-icon <out.png>
let size: CGFloat = 1024
let rgb = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func gradient(_ c: [CGColor]) -> CGGradient { CGGradient(colorsSpace: rgb, colors: c as CFArray, locations: nil)! }
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }
func fill(_ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// Background squircle with a blue rim glow.
let bgRect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 36, dy: 36)
let bg = rounded(bgRect, 210)
fill(bg, gradient([color(0x0E1A3A), color(0x060B1C)]), from: CGPoint(x: 0, y: size), to: CGPoint(x: size, y: 0))
ctx.saveGState(); ctx.addPath(bg); ctx.clip()
ctx.setShadow(offset: .zero, blur: 60, color: color(0x2F6BFF, 0.9))
ctx.setStrokeColor(color(0x3B7BFF, 0.75)); ctx.setLineWidth(10)
ctx.addPath(bg); ctx.strokePath()
ctx.restoreGState()

/// A card is a slab: a darker copy below for thickness, a glow, then the gradient face.
func card(_ r: CGRect, angle: CGFloat, top: UInt32, bottom: UInt32, edge: UInt32) {
    ctx.saveGState()
    ctx.translateBy(x: r.midX, y: r.midY); ctx.rotate(by: angle); ctx.translateBy(x: -r.midX, y: -r.midY)
    let face = rounded(r, 64)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 50, color: color(0x2A5CFF, 0.8))
    ctx.addPath(rounded(r.offsetBy(dx: 0, dy: -22), 64)); ctx.setFillColor(color(edge)); ctx.fillPath()
    ctx.restoreGState()
    fill(face, gradient([color(top), color(bottom)]), from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.maxX, y: r.minY))
    ctx.saveGState(); ctx.addPath(face); ctx.setStrokeColor(color(0xFFFFFF, 0.28)); ctx.setLineWidth(5); ctx.strokePath(); ctx.restoreGState()
    ctx.restoreGState()
}

let tilt: CGFloat = 0.06
card(CGRect(x: 230, y: 150, width: 630, height: 460), angle: tilt, top: 0x3348F0, bottom: 0x3A22C8, edge: 0x1B1590)
card(CGRect(x: 195, y: 215, width: 630, height: 460), angle: tilt, top: 0x2F6BFF, bottom: 0x2C3BE0, edge: 0x1A2AA8)

// Top card: the calendar page.
let page = CGRect(x: 150, y: 290, width: 650, height: 500)
ctx.saveGState()
ctx.translateBy(x: page.midX, y: page.midY); ctx.rotate(by: tilt); ctx.translateBy(x: -page.midX, y: -page.midY)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 60, color: color(0x2A6CFF, 0.9))
ctx.addPath(rounded(page.offsetBy(dx: 0, dy: -24), 64)); ctx.setFillColor(color(0x1C4FD8)); ctx.fillPath()
ctx.restoreGState()
let face = rounded(page, 64)
fill(face, gradient([color(0x46B4FF), color(0x2E7CFF), color(0x2B55F0)]), from: CGPoint(x: page.minX, y: page.maxY), to: CGPoint(x: page.maxX, y: page.minY))
// Header band.
ctx.saveGState(); ctx.addPath(face); ctx.clip()
fill(CGPath(rect: CGRect(x: page.minX, y: page.maxY - 120, width: page.width, height: 120), transform: nil),
     gradient([color(0x63D0FF, 0.95), color(0x3C8DFF, 0.95)]), from: CGPoint(x: page.minX, y: page.maxY), to: CGPoint(x: page.maxX, y: page.maxY - 120))
ctx.setFillColor(color(0x1B3FB8, 0.35)); ctx.fill(CGRect(x: page.minX, y: page.maxY - 124, width: page.width, height: 6))
ctx.restoreGState()
ctx.addPath(face); ctx.setStrokeColor(color(0xFFFFFF, 0.35)); ctx.setLineWidth(5); ctx.strokePath()
// Binding rings.
for x in [page.minX + 170, page.maxX - 170] {
    let ring = rounded(CGRect(x: x - 26, y: page.maxY - 70, width: 52, height: 130), 26)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x0A1E6E, 0.6))
    fill(ring, gradient([color(0xFFFFFF), color(0xBFD8FF)]), from: CGPoint(x: x - 26, y: 0), to: CGPoint(x: x + 26, y: 0))
    ctx.restoreGState()
}
// Day grid: 5 columns x 3 rows, one highlighted.
let cols = 5, rows = 3
let gx = page.minX + 56, gy = page.minY + 46
let cell: CGFloat = 86, gap: CGFloat = 22
for r in 0..<rows {
    for c in 0..<cols {
        let rect = CGRect(x: gx + CGFloat(c) * (cell + gap), y: gy + CGFloat(rows - 1 - r) * (cell + gap) - 6, width: cell, height: cell)
        if r == 1 && c == 3 {
            let hi = rounded(rect.insetBy(dx: -8, dy: -8), 30)
            ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 50, color: color(0x5CFFC8, 0.9))
            fill(hi, gradient([color(0xB8FFF0), color(0x3BE6B0), color(0x22C4E8)]), from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.maxX, y: rect.minY))
            ctx.restoreGState()
            ctx.addPath(hi); ctx.setStrokeColor(color(0xFFFFFF, 0.7)); ctx.setLineWidth(4); ctx.strokePath()
        } else {
            ctx.addPath(rounded(rect, 22)); ctx.setFillColor(color(0xFFFFFF, 0.22)); ctx.fillPath()
        }
    }
}
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
