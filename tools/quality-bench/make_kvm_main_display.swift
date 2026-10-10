// Makes the JetKVM's HDMI display the main display (menu bar, Dock, absolute
// pointer). `swift main.swift revert` makes another display main again.
import CoreGraphics
import Foundation

var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
CGGetActiveDisplayList(16, &ids, &count)
let displays = Array(ids.prefix(Int(count)))
for d in displays {
    print("display \(d) vendor \(String(CGDisplayVendorNumber(d), radix: 16)) bounds \(CGDisplayBounds(d))\(CGDisplayIsMain(d) != 0 ? " main" : "")")
}
let isKVM = { (d: CGDirectDisplayID) in CGDisplayVendorNumber(d) == 0x28B4 } // EDID manufacturer "JET"
let revert = CommandLine.arguments.contains("revert")
guard let target = revert ? displays.first(where: { !isKVM($0) }) : displays.first(where: isKVM) else {
    print("no matching display; nothing changed")
    exit(1)
}
if CGDisplayIsMain(target) != 0 {
    print("display \(target) is already main")
    exit(0)
}
let origin = CGDisplayBounds(target).origin
var config: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&config) == .success else { exit(2) }
for d in displays {
    let b = CGDisplayBounds(d)
    CGConfigureDisplayOrigin(config, d, Int32(b.origin.x - origin.x), Int32(b.origin.y - origin.y))
}
let result = CGCompleteDisplayConfiguration(config, .permanently)
print("made display \(target) main: \(result == .success ? "ok" : "error \(result.rawValue)")")
