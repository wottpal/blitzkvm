// Renders the 1920x1080 ground-truth test image (sRGB, 1x, grayscale text
// antialiasing as macOS draws it) used to score the KVM stream.
import AppKit
import CoreText

let W = 1920, H = 1080
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Top-left origin like a screen.
ctx.translateBy(x: 0, y: CGFloat(H))
ctx.scaleBy(x: 1, y: -1)
ctx.setShouldSmoothFonts(false)
ctx.setAllowsFontSmoothing(false)
ctx.setShouldSubpixelPositionFonts(true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, 1])! }
func fill(_ r: CGRect, _ c: CGColor) { ctx.setFillColor(c); ctx.fill(r) }

func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor, weight: NSFont.Weight = .regular, mono: Bool = false) {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.saveGState()
    // Undo the flip for glyphs, baseline at y.
    ctx.translateBy(x: x, y: y)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

let sample = "The quick brown fox jumps over the lazy dog 0123456789 äöüß ÄÖÜ (){}[] ~!@#$%^&*"

// 1. Light half: text sizes, colors.
fill(CGRect(x: 0, y: 0, width: 960, height: 1080), rgb(1, 1, 1))
var y: CGFloat = 40
for size in [9, 10, 11, 12, 13, 14, 16, 20, 28] as [CGFloat] {
    text("\(Int(size))px  " + sample, x: 16, y: y, size: size, color: rgb(0, 0, 0))
    y += size * 1.6 + 6
}
for (name, c) in [("red", rgb(0.85, 0.1, 0.1)), ("blue", rgb(0.1, 0.25, 0.9)), ("green", rgb(0.05, 0.55, 0.15)), ("gray", rgb(0.55, 0.55, 0.55)), ("orange", rgb(1, 0.55, 0))] {
    text("13px \(name)  " + sample, x: 16, y: y, size: 13, color: c)
    y += 22
}
text("13px semibold  " + sample, x: 16, y: y, size: 13, color: rgb(0, 0, 0), weight: .semibold); y += 24
for line in ["func render(_ frame: CVPixelBuffer) -> VideoLayout? {", "    let l = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080)", "    return l.width > 0 ? l : nil  // 0O1lI| ;:,. `'\"", "}"] {
    text(line, x: 16, y: y, size: 12, color: rgb(0.1, 0.1, 0.1), mono: true)
    y += 17
}
// UI widgets on light.
for i in 0..<5 {
    let r = CGRect(x: 16 + CGFloat(i) * 120, y: y + 10, width: 104, height: 26)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
    ctx.setFillColor(i == 0 ? rgb(0.0, 0.48, 1.0) : rgb(0.92, 0.92, 0.93))
    ctx.fillPath()
    text(i == 0 ? "Default" : "Button \(i)", x: r.minX + 18, y: r.minY + 18, size: 13, color: i == 0 ? rgb(1, 1, 1) : rgb(0, 0, 0))
}

// 2. Dark half: dark-mode text.
fill(CGRect(x: 960, y: 0, width: 960, height: 540), rgb(0.12, 0.12, 0.13))
y = 40
for size in [10, 11, 12, 13, 14, 16, 20] as [CGFloat] {
    text("\(Int(size))px  " + sample, x: 976, y: y, size: size, color: rgb(0.92, 0.92, 0.92))
    y += size * 1.6 + 6
}
for (name, c) in [("blue", rgb(0.35, 0.6, 1)), ("green", rgb(0.3, 0.85, 0.4)), ("yellow", rgb(1, 0.85, 0.2)), ("gray", rgb(0.6, 0.6, 0.62))] {
    text("13px \(name)  " + sample, x: 976, y: y, size: 13, color: c)
    y += 22
}
for line in ["$ go test -race ./pkg/... && make -C macos selftest", "ok  github.com/lkarlslund/jetkvm-desktop/pkg/video 0.412s", "PASS: 34 tests, 0 failures  [0O1lI|]"] {
    text(line, x: 976, y: y, size: 12, color: rgb(0.75, 0.95, 0.75), mono: true)
    y += 17
}

// 3. Bottom right: resolution and color targets.
let rx: CGFloat = 960, ry: CGFloat = 540
fill(CGRect(x: rx, y: ry, width: 960, height: 540), rgb(0.5, 0.5, 0.5))
// 1-px line gratings and checkerboards (black/white).
for (i, period) in [1, 2, 3, 4].enumerated() {
    let box = CGRect(x: rx + 16 + CGFloat(i) * 112, y: ry + 16, width: 100, height: 100)
    fill(box, rgb(1, 1, 1))
    var xx = Int(box.minX)
    while xx < Int(box.maxX) {
        fill(CGRect(x: CGFloat(xx), y: box.minY, width: CGFloat(period), height: 48), rgb(0, 0, 0))
        xx += period * 2
    }
    var yy = Int(box.minY) + 52
    while yy < Int(box.maxY) {
        fill(CGRect(x: box.minX, y: CGFloat(yy), width: 100, height: CGFloat(period)), rgb(0, 0, 0))
        yy += period * 2
    }
}
let cb = CGRect(x: rx + 464, y: ry + 16, width: 100, height: 100)
for yy in 0..<100 { for xx in 0..<100 where (xx + yy) % 2 == 0 { fill(CGRect(x: cb.minX + CGFloat(xx), y: cb.minY + CGFloat(yy), width: 1, height: 1), rgb(0, 0, 0)) } }
fill(CGRect(x: rx + 576, y: ry + 16, width: 100, height: 100), rgb(1, 1, 1))
for yy in stride(from: 0, to: 100, by: 4) { for xx in stride(from: 0, to: 100, by: 4) { fill(CGRect(x: rx + 576 + CGFloat(xx), y: ry + 16 + CGFloat(yy), width: 1, height: 1), rgb(0, 0, 0)) } }
// Color patches.
let patches: [CGColor] = [rgb(1, 0, 0), rgb(0, 1, 0), rgb(0, 0, 1), rgb(0, 1, 1), rgb(1, 0, 1), rgb(1, 1, 0), rgb(0.85, 0.65, 0.55), rgb(0.2, 0.4, 0.25),
                          rgb(0.0, 0.48, 1.0), rgb(1, 0.23, 0.19), rgb(0.2, 0.78, 0.35), rgb(0.69, 0.32, 0.87)]
for (i, c) in patches.enumerated() {
    fill(CGRect(x: rx + 16 + CGFloat(i % 6) * 76, y: ry + 132 + CGFloat(i / 6) * 60, width: 70, height: 54), c)
}
// Gray ramp (17 steps) and a smooth gradient.
for i in 0...16 {
    let v = CGFloat(i) / 16
    fill(CGRect(x: rx + 16 + CGFloat(i) * 54, y: ry + 260, width: 54, height: 40), rgb(v, v, v))
}
let grad = CGGradient(colorsSpace: space, colors: [rgb(0, 0, 0), rgb(1, 1, 1)] as CFArray, locations: [0, 1])!
ctx.saveGState(); ctx.clip(to: CGRect(x: rx + 16, y: ry + 310, width: 918, height: 30))
ctx.drawLinearGradient(grad, start: CGPoint(x: rx + 16, y: 0), end: CGPoint(x: rx + 934, y: 0), options: [])
ctx.restoreGState()
let grad2 = CGGradient(colorsSpace: space, colors: [rgb(0.9, 0.2, 0.3), rgb(0.2, 0.4, 0.95), rgb(0.2, 0.85, 0.5)] as CFArray, locations: [0, 0.5, 1])!
ctx.saveGState(); ctx.clip(to: CGRect(x: rx + 16, y: ry + 346, width: 918, height: 30))
ctx.drawLinearGradient(grad2, start: CGPoint(x: rx + 16, y: 0), end: CGPoint(x: rx + 934, y: 0), options: [])
ctx.restoreGState()
// Photo-like texture: smooth noise.
var seed: UInt64 = 42
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
for yy in stride(from: 0, to: 140, by: 2) {
    for xx in stride(from: 0, to: 440, by: 2) {
        let fx = CGFloat(xx) / 440, fy = CGFloat(yy) / 140
        let base = 0.5 + 0.3 * sin(fx * 9 + fy * 5) * cos(fy * 7)
        let n = (rnd() - 0.5) * 0.25
        fill(CGRect(x: rx + 16 + CGFloat(xx), y: ry + 388 + CGFloat(yy), width: 2, height: 2), rgb(base + n, base * 0.8 + n, 0.6 - base * 0.4 + n))
    }
}
text("Small labels 9px: Downloads · Programme · Öffentlich · 12 Objekte, 740,81 GB verfügbar", x: rx + 472, y: ry + 400, size: 9, color: rgb(1, 1, 1))
text("10px on gray: The quick brown fox", x: rx + 472, y: ry + 420, size: 10, color: rgb(0, 0, 0))
text("11px on gray: jumps over the lazy dog", x: rx + 472, y: ry + 440, size: 11, color: rgb(1, 1, 1))
// Corner alignment markers (1-px exact).
for (cx, cy) in [(0, 0), (W - 8, 0), (0, H - 8), (W - 8, H - 8)] {
    fill(CGRect(x: cx, y: cy, width: 8, height: 8), rgb(1, 0, 1))
    fill(CGRect(x: cx + 2, y: cy + 2, width: 4, height: 4), rgb(0, 1, 0))
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
