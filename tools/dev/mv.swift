import CoreGraphics
import Foundation
let a = CommandLine.arguments
let x = Double(a[1])!, y = Double(a[2])!
let p = CGPoint(x: x, y: y)
CGWarpMouseCursorPosition(p)
CGAssociateMouseAndMouseCursorPosition(1)
let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
e?.post(tap: .cghidEventTap)
