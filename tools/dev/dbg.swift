import Foundation
let a = CommandLine.arguments
var info: [String: Any] = ["cmd": a[1]]
if a.count > 2 { info["arg"] = a[2] }
DistributedNotificationCenter.default().postNotificationName(.init("local.isle.debug"), object: nil, userInfo: info, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
