import AppKit
// montage <out> <img>...  stacks images vertically at half size
let a = CommandLine.arguments
let imgs = a[2...].compactMap { NSImage(contentsOfFile: $0) }
let w = imgs.map { $0.size.width }.max() ?? 0
let h = imgs.reduce(0) { $0 + $1.size.height }
let out = NSImage(size: NSSize(width: w, height: h))
out.lockFocus()
var y = h
for i in imgs { y -= i.size.height; i.draw(at: NSPoint(x: 0, y: y), from: .zero, operation: .copy, fraction: 1) }
out.unlockFocus()
let rep = NSBitmapImageRep(data: out.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
