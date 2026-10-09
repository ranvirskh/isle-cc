// Draws Isle's oasis app icon (original artwork) and writes AppIcon.icns.
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
        // Sun.
        NSColor(red: 1, green: 0.93, blue: 0.62, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: 560 * u, y: 520 * u, width: 190 * u, height: 190 * u)).fill()
        // Far dune.
        let dune1 = NSBezierPath()
        dune1.move(to: NSPoint(x: 100 * u, y: 420 * u))
        dune1.curve(to: NSPoint(x: 560 * u, y: 430 * u), controlPoint1: NSPoint(x: 260 * u, y: 520 * u), controlPoint2: NSPoint(x: 420 * u, y: 380 * u))
        dune1.curve(to: NSPoint(x: 924 * u, y: 400 * u), controlPoint1: NSPoint(x: 700 * u, y: 480 * u), controlPoint2: NSPoint(x: 820 * u, y: 440 * u))
        dune1.line(to: NSPoint(x: 924 * u, y: 100 * u)); dune1.line(to: NSPoint(x: 100 * u, y: 100 * u)); dune1.close()
        NSColor(red: 0.86, green: 0.47, blue: 0.36, alpha: 1).setFill(); dune1.fill()
        // Water pool.
        let pool = NSBezierPath(ovalIn: NSRect(x: 190 * u, y: 200 * u, width: 640 * u, height: 190 * u))
        NSGradient(colors: [NSColor(red: 0.30, green: 0.85, blue: 0.85, alpha: 1), NSColor(red: 0.06, green: 0.50, blue: 0.62, alpha: 1)])!.draw(in: pool, angle: 90)
        // Sun reflection.
        NSColor(red: 1, green: 0.95, blue: 0.75, alpha: 0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: 560 * u, y: 270 * u, width: 90 * u, height: 22 * u)).fill()
        // Near sand.
        let dune2 = NSBezierPath()
        dune2.move(to: NSPoint(x: 100 * u, y: 100 * u))
        dune2.line(to: NSPoint(x: 100 * u, y: 250 * u))
        dune2.curve(to: NSPoint(x: 520 * u, y: 150 * u), controlPoint1: NSPoint(x: 260 * u, y: 330 * u), controlPoint2: NSPoint(x: 400 * u, y: 190 * u))
        dune2.curve(to: NSPoint(x: 924 * u, y: 240 * u), controlPoint1: NSPoint(x: 680 * u, y: 110 * u), controlPoint2: NSPoint(x: 820 * u, y: 150 * u))
        dune2.line(to: NSPoint(x: 924 * u, y: 100 * u)); dune2.close()
        NSColor(red: 0.95, green: 0.74, blue: 0.48, alpha: 1).setFill(); dune2.fill()

        // Palm trees.
        func palm(base: NSPoint, height: CGFloat, lean: CGFloat, scale: CGFloat) {
            let trunk = NSBezierPath()
            let top = NSPoint(x: base.x + lean, y: base.y + height)
            trunk.move(to: base)
            trunk.curve(to: top, controlPoint1: NSPoint(x: base.x + lean * 0.1, y: base.y + height * 0.5), controlPoint2: NSPoint(x: top.x - lean * 0.4, y: top.y - height * 0.2))
            trunk.lineWidth = 22 * scale * u; trunk.lineCapStyle = .round
            NSColor(red: 0.33, green: 0.20, blue: 0.20, alpha: 1).setStroke(); trunk.stroke()
            for a in stride(from: -20.0, through: 200.0, by: 36.0) {
                let rad = a * .pi / 180
                let len = 150 * scale * u
                let end = NSPoint(x: top.x + cos(rad) * len, y: top.y + sin(rad) * len * 0.55 - 40 * scale * u)
                let mid = NSPoint(x: top.x + cos(rad) * len * 0.5, y: top.y + sin(rad) * len * 0.5 + 38 * scale * u)
                let frond = NSBezierPath()
                frond.move(to: top); frond.curve(to: end, controlPoint1: mid, controlPoint2: mid)
                frond.lineWidth = 16 * scale * u; frond.lineCapStyle = .round
                NSColor(red: 0.12, green: 0.40, blue: 0.30, alpha: 1).setStroke(); frond.stroke()
            }
        }
        palm(base: NSPoint(x: 300 * u, y: 300 * u), height: 330 * u, lean: -50 * u, scale: 1.0)
        palm(base: NSPoint(x: 420 * u, y: 285 * u), height: 240 * u, lean: 55 * u, scale: 0.75)
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
