import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let s = NSScreen.screens[0]
let r = NSRect(x: s.frame.midX - 400, y: s.frame.maxY - 300, width: 800, height: 300)
let w = NSWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
w.backgroundColor = NSColor(white: 0.55, alpha: 1)
w.level = .floating
w.ignoresMouseEvents = true
w.collectionBehavior = [.canJoinAllSpaces, .stationary]
w.orderFrontRegardless()
app.run()
