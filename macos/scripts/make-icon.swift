// Renders the app icon: `swift scripts/make-icon.swift Support/AppIcon.icns`
// (run from macos/). A remote screen with a pointer on a deep blue tile,
// drawn with Core Graphics on the macOS icon grid (824 pt tile in 1024).
import AppKit
import CoreGraphics

func render(size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    let rgb = CGColorSpace(name: CGColorSpace.displayP3)!
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: rgb, components: [r, g, b, a])! }

    // Tile with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0.07, 0.09, 0.18))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(colorsSpace: rgb, colors: [color(0.16, 0.24, 0.52), color(0.05, 0.07, 0.17)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // A faint glow behind the screen.
    let glow = CGGradient(colorsSpace: rgb, colors: [color(0.35, 0.65, 1, 0.35), color(0.35, 0.65, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 420, options: [])
    ctx.restoreGState()

    // Monitor: bezel, screen, stand.
    let bezel = CGRect(x: 214, y: 352, width: 596, height: 400)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.45))
    ctx.addPath(CGPath(roundedRect: bezel, cornerWidth: 44, cornerHeight: 44, transform: nil))
    ctx.setFillColor(color(0.93, 0.95, 0.99))
    ctx.fillPath()
    ctx.restoreGState()
    let screen = bezel.insetBy(dx: 26, dy: 26)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.clip()
    let screenGradient = CGGradient(colorsSpace: rgb, colors: [color(0.18, 0.78, 0.95), color(0.20, 0.36, 0.95)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(screenGradient, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
    // A window on the remote desktop.
    let window = CGRect(x: screen.minX + 60, y: screen.minY + 70, width: 300, height: 190)
    ctx.addPath(CGPath(roundedRect: window, cornerWidth: 16, cornerHeight: 16, transform: nil))
    ctx.setFillColor(color(1, 1, 1, 0.9))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: window.minX, y: window.maxY - 36, width: window.width, height: 36), cornerWidth: 16, cornerHeight: 16, transform: nil))
    ctx.setFillColor(color(0.85, 0.89, 0.97))
    ctx.fillPath()
    for (i, c) in [color(1, 0.37, 0.34), color(1, 0.74, 0.18), color(0.16, 0.78, 0.25)].enumerated() {
        ctx.setFillColor(c)
        ctx.fillEllipse(in: CGRect(x: window.minX + 18 + CGFloat(i) * 24, y: window.maxY - 26, width: 15, height: 15))
    }
    for line in 0..<4 {
        let width: CGFloat = [220, 180, 240, 140][line]
        ctx.addPath(CGPath(roundedRect: CGRect(x: window.minX + 22, y: window.maxY - 70 - CGFloat(line) * 30, width: width, height: 12),
                           cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(color(0.62, 0.68, 0.82))
        ctx.fillPath()
    }
    ctx.restoreGState()
    // Stand.
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: 462, y: 352))
    neck.addLine(to: CGPoint(x: 562, y: 352))
    neck.addLine(to: CGPoint(x: 580, y: 286))
    neck.addLine(to: CGPoint(x: 444, y: 286))
    neck.closeSubpath()
    ctx.addPath(neck)
    ctx.setFillColor(color(0.80, 0.84, 0.92))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 384, y: 262, width: 256, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil))
    ctx.setFillColor(color(0.93, 0.95, 0.99))
    ctx.fillPath()

    // Pointer, crossing the screen's edge: control from outside.
    let pointer = CGMutablePath()
    let tip = CGPoint(x: 600, y: 520)
    pointer.move(to: tip)
    pointer.addLine(to: CGPoint(x: tip.x, y: tip.y - 250))
    pointer.addLine(to: CGPoint(x: tip.x + 58, y: tip.y - 196))
    pointer.addLine(to: CGPoint(x: tip.x + 100, y: tip.y - 288))
    pointer.addLine(to: CGPoint(x: tip.x + 142, y: tip.y - 270))
    pointer.addLine(to: CGPoint(x: tip.x + 100, y: tip.y - 180))
    pointer.addLine(to: CGPoint(x: tip.x + 176, y: tip.y - 176))
    pointer.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0, 0, 0, 0.5))
    ctx.addPath(pointer)
    ctx.setFillColor(color(0.06, 0.07, 0.12))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(pointer)
    ctx.setStrokeColor(color(1, 1, 1))
    ctx.setLineWidth(18)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.addPath(pointer)
    ctx.setFillColor(color(0.06, 0.07, 0.12))
    ctx.fillPath()
    return ctx.makeImage()!
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = NSBitmapImageRep(cgImage: render(size: base * scale))
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(task.terminationStatus)
