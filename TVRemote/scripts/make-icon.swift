// Renders the 1024×1024 app icon: a TV with a remote D-pad on its screen.
// Usage: swift scripts/make-icon.swift out.png   (scripts/make-icon.sh turns it into Support/AppIcon.icns)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Body: the macOS icon grid's 824 pt rounded square with a soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
color(0x2A3FB8).setFill()
bodyPath.fill()
ctx.restoreGState()

ctx.saveGState()
bodyPath.addClip()
NSGradient(starting: color(0x6A8BFF), ending: color(0x2433A6))!.draw(in: body, angle: -90)
// Soft sheen on the upper half.
NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: NSColor.white.withAlphaComponent(0))!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
ctx.restoreGState()

NSColor.white.setStroke()
NSColor.white.setFill()

// Screen.
let screen = NSBezierPath(roundedRect: NSRect(x: 236, y: 400, width: 552, height: 352), xRadius: 56, yRadius: 56)
NSColor.white.withAlphaComponent(0.12).setFill()
screen.fill()
screen.lineWidth = 44
screen.stroke()

// Stand.
let neck = NSBezierPath()
neck.move(to: NSPoint(x: 512, y: 378))
neck.line(to: NSPoint(x: 512, y: 318))
neck.lineWidth = 40
neck.stroke()
let base = NSBezierPath()
base.move(to: NSPoint(x: 404, y: 300))
base.line(to: NSPoint(x: 620, y: 300))
base.lineWidth = 40
base.lineCapStyle = .round
base.stroke()

// Remote D-pad on the screen: ring, centre button and four direction notches.
let center = NSPoint(x: 512, y: 576)
let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 104, y: center.y - 104, width: 208, height: 208))
ring.lineWidth = 26
ring.stroke()
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - 36, y: center.y - 36, width: 72, height: 72)).fill()
for angle in stride(from: 0.0, to: 360.0, by: 90.0) {
    let r = angle * .pi / 180
    let p = NSPoint(x: center.x + cos(r) * 66, y: center.y + sin(r) * 66)
    NSBezierPath(ovalIn: NSRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)).fill()
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
