// Draws Isle's palm tree app icon (original artwork) and writes AppIcon.icns.
// usage: swiftc -O tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon Resources
import AppKit

func draw(size s: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let u = s / 1024
        let ctx = NSGraphicsContext.current!.cgContext
        // macOS icon body: 824pt rounded square centered in 1024.
        let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
        let clip = NSBezierPath(roundedRect: body, xRadius: 185 * u, yRadius: 185 * u)
        ctx.saveGState()
        NSShadow().apply(offset: NSSize(width: 0, height: -10 * u), blur: 24 * u, alpha: 0.35)
        NSColor.black.setFill(); clip.fill()
        ctx.restoreGState()
        clip.addClip()

        // Sky: warm dusk to teal.
        NSGradient(colors: [NSColor(red: 1.0, green: 0.62, blue: 0.30, alpha: 1), NSColor(red: 0.98, green: 0.45, blue: 0.40, alpha: 1),
                            NSColor(red: 0.36, green: 0.28, blue: 0.55, alpha: 1)],
                   atLocations: [0, 0.45, 1], colorSpace: .sRGB)!.draw(in: body, angle: 90)
        // Sun, low behind the tree.
        NSColor(red: 1, green: 0.93, blue: 0.62, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: 430 * u, y: 330 * u, width: 360 * u, height: 360 * u)).fill()
        // Sea band.
        let sea = NSBezierPath(rect: NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 250 * u))
        NSGradient(colors: [NSColor(red: 0.30, green: 0.80, blue: 0.82, alpha: 1), NSColor(red: 0.07, green: 0.42, blue: 0.58, alpha: 1)])!.draw(in: sea, angle: -90)
        // Island of sand.
        let sand = NSBezierPath()
        sand.move(to: NSPoint(x: 230 * u, y: 250 * u))
        sand.curve(to: NSPoint(x: 512 * u, y: 330 * u), controlPoint1: NSPoint(x: 300 * u, y: 330 * u), controlPoint2: NSPoint(x: 420 * u, y: 345 * u))
        sand.curve(to: NSPoint(x: 800 * u, y: 250 * u), controlPoint1: NSPoint(x: 610 * u, y: 345 * u), controlPoint2: NSPoint(x: 730 * u, y: 330 * u))
        sand.curve(to: NSPoint(x: 230 * u, y: 250 * u), controlPoint1: NSPoint(x: 640 * u, y: 190 * u), controlPoint2: NSPoint(x: 390 * u, y: 190 * u))
        NSColor(red: 0.96, green: 0.77, blue: 0.50, alpha: 1).setFill(); sand.fill()

        // One big palm tree.
        let base = NSPoint(x: 500 * u, y: 290 * u)
        let top = NSPoint(x: 560 * u, y: 700 * u)
        let trunk = NSBezierPath()
        trunk.move(to: base)
        trunk.curve(to: top, controlPoint1: NSPoint(x: 440 * u, y: 450 * u), controlPoint2: NSPoint(x: 500 * u, y: 600 * u))
        trunk.lineWidth = 46 * u; trunk.lineCapStyle = .round
        NSColor(red: 0.36, green: 0.21, blue: 0.18, alpha: 1).setStroke(); trunk.stroke()
        // Trunk rings.
        NSColor(red: 0.24, green: 0.14, blue: 0.13, alpha: 0.55).setStroke()
        for t in stride(from: 0.12, through: 0.92, by: 0.1) {
            let y = base.y + (top.y - base.y) * CGFloat(t)
            let x = base.x + (top.x - base.x) * CGFloat(t * t) - 8 * u
            let ring = NSBezierPath(); ring.move(to: NSPoint(x: x - 20 * u, y: y)); ring.line(to: NSPoint(x: x + 20 * u, y: y - 6 * u))
            ring.lineWidth = 5 * u; ring.stroke()
        }
        // Fronds: curved leaves with a lighter midrib.
        let angles: [CGFloat] = [-10, 28, 62, 100, 138, 172, 205]
        for (i, deg) in angles.enumerated() {
            let rad = deg * .pi / 180
            let len = (i % 2 == 0 ? 300 : 260) * u
            let end = NSPoint(x: top.x + cos(rad) * len, y: top.y + sin(rad) * len * 0.45 - 110 * u)
            let ctrl = NSPoint(x: top.x + cos(rad) * len * 0.55, y: top.y + sin(rad) * len * 0.55 + 90 * u)
            let leaf = NSBezierPath()
            leaf.move(to: top); leaf.curve(to: end, controlPoint1: ctrl, controlPoint2: ctrl)
            leaf.lineWidth = 46 * u; leaf.lineCapStyle = .round
            NSColor(red: i % 2 == 0 ? 0.10 : 0.16, green: i % 2 == 0 ? 0.45 : 0.55, blue: 0.30, alpha: 1).setStroke(); leaf.stroke()
            let rib = NSBezierPath()
            rib.move(to: top); rib.curve(to: end, controlPoint1: ctrl, controlPoint2: ctrl)
            rib.lineWidth = 6 * u; rib.lineCapStyle = .round
            NSColor(red: 0.55, green: 0.85, blue: 0.55, alpha: 0.6).setStroke(); rib.stroke()
        }
        // Coconuts.
        NSColor(red: 0.30, green: 0.18, blue: 0.14, alpha: 1).setFill()
        for dx in [-26.0, 4.0, 30.0] { NSBezierPath(ovalIn: NSRect(x: (top.x / u + dx - 18) * u, y: (top.y / u - 58) * u, width: 36 * u, height: 36 * u)).fill() }
        return true
    }
}

extension NSShadow {
    func apply(offset: NSSize, blur: CGFloat, alpha: CGFloat) {
        shadowOffset = offset; shadowBlurRadius = blur; shadowColor = NSColor.black.withAlphaComponent(alpha); set()
    }
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let set = "\(out)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (name, px) in [("16", 16), ("16@2x", 32), ("32", 32), ("32@2x", 64), ("128", 128), ("128@2x", 256), ("256", 256), ("256@2x", 512), ("512", 512), ("512@2x", 1024)] {
    let img = draw(size: CGFloat(px))
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    let label = name.hasSuffix("@2x") ? "\(name.dropLast(3))x\(name.dropLast(3))@2x" : "\(name)x\(name)"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(set)/icon_\(label).png"))
}
