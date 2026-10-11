// gen.swift OUTDIR COUNT SEED: random desktop-like scenes rendered at 1x and
// natively at 2x (same layout), as training pairs for a 2x text upscaler.
import AppKit
import CoreText

let out = CommandLine.arguments[1]
let count = Int(CommandLine.arguments[2])!
var seed = UInt64(CommandLine.arguments[3])!
func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
func pick<T>(_ a: [T]) -> T { a[Int(rnd() * Double(a.count)) % a.count] }

let N = 384
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let fonts = ["SF", "SFMono", "Helvetica Neue", "Menlo", "Georgia", "Avenir Next", "Times New Roman", "Arial"]
let words = ["The", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "Downloads", "Programme", "Öffentlich", "Objekte",
             "verfügbar", "func", "render", "return", "let", "var", "0123456789", "Settings", "General", "Display", "Network",
             "Wi-Fi", "Bluetooth", "Battery", "Finder", "Terminal", "git", "commit", "push", "(){}[]", "~!@#$%^&*", "äöüß", "ÄÖÜ",
             "Mail", "Calendar", "Safari", "Xcode", "README.md", "main.swift", "1.2.3", "100%", "12:34", "Mon", "Oct", "2026",
             "Cancel", "OK", "Save", "Open", "Quit", "Edit", "View", "Window", "Help", "jetkvm", "desktop", "€", "→", "•", "—"]

struct Scene { var bg: [Double]; var ops: [(CGContext) -> Void] }

func color(_ c: [Double]) -> CGColor { CGColor(colorSpace: space, components: [c[0], c[1], c[2], 1])! }
func randomColor(contrastTo bg: [Double]) -> [Double] {
    let bgL = 0.299 * bg[0] + 0.587 * bg[1] + 0.114 * bg[2]
    for _ in 0..<20 {
        var c = [rnd(), rnd(), rnd()]
        if rnd() < 0.5 { let g = bgL > 0.5 ? rnd() * 0.3 : 0.7 + rnd() * 0.3; c = [g, g, g] }
        let l = 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]
        if abs(l - bgL) > 0.3 { return c }
    }
    return bgL > 0.5 ? [0, 0, 0] : [1, 1, 1]
}

func makeScene() -> Scene {
    let r = rnd()
    var bg: [Double]
    if r < 0.4 { let g = 0.9 + rnd() * 0.1; bg = [g, g, g] }
    else if r < 0.75 { let g = 0.08 + rnd() * 0.15; bg = [g, g, g + 0.01] }
    else { bg = [rnd(), rnd(), rnd()] }
    var ops: [(CGContext) -> Void] = []
    // UI shapes.
    for _ in 0..<Int(rnd() * 6) {
        let x = Double(Int(rnd() * Double(N - 60))), y = Double(Int(rnd() * Double(N - 30)))
        let w = Double(20 + Int(rnd() * 160)), h = Double(10 + Int(rnd() * 40))
        let c = rnd() < 0.5 ? randomColor(contrastTo: bg) : [rnd(), rnd(), rnd()]
        let radius = pick([0.0, 4, 6, 8])
        let stroke = rnd() < 0.3
        ops.append { ctx in
            let path = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(path)
            if stroke { ctx.setStrokeColor(color(c)); ctx.setLineWidth(1); ctx.strokePath() } else { ctx.setFillColor(color(c)); ctx.fillPath() }
        }
    }
    if rnd() < 0.25 {
        let y = Double(Int(rnd() * Double(N - 40))), c1 = [rnd(), rnd(), rnd()], c2 = [rnd(), rnd(), rnd()]
        ops.append { ctx in
            let g = CGGradient(colorsSpace: space, colors: [color(c1), color(c2)] as CFArray, locations: [0, 1])!
            ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: y, width: Double(N), height: 30))
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: Double(N), y: 0), options: [])
            ctx.restoreGState()
        }
    }
    // Text lines.
    var y = 6.0 + Double(Int(rnd() * 10))
    while y < Double(N) {
        let size = pick([9.0, 10, 11, 11, 12, 12, 13, 13, 13, 14, 14, 15, 16, 17, 18, 20, 22, 24, 28])
        let fontName = pick(fonts)
        let weight = pick([NSFont.Weight.regular, .regular, .regular, .medium, .semibold, .bold])
        let c = rnd() < 0.8 ? randomColor(contrastTo: bg) : [rnd(), rnd(), rnd()]
        var s = ""
        for _ in 0..<(2 + Int(rnd() * 10)) { s += pick(words) + " " }
        let x = Double(Int(rnd() * 120)) - 20
        let baseline = (y + size).rounded()
        ops.append { ctx in
            let font: NSFont
            switch fontName {
            case "SF": font = NSFont.systemFont(ofSize: size, weight: weight)
            case "SFMono": font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            default: font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
            }
            let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color(c))!])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.saveGState()
            ctx.translateBy(x: x, y: baseline)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        y += size * (1.3 + rnd() * 0.8)
    }
    return Scene(bg: bg, ops: ops)
}

func render(_ scene: Scene, scale: Int, to path: String) {
    let ctx = CGContext(data: nil, width: N * scale, height: N * scale, bitsPerComponent: 8, bytesPerRow: N * scale * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(N * scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    ctx.setShouldSmoothFonts(false)
    ctx.setAllowsFontSmoothing(false)
    ctx.setShouldSubpixelPositionFonts(true)
    ctx.setFillColor(color(scene.bg))
    ctx.fill(CGRect(x: 0, y: 0, width: N, height: N))
    for op in scene.ops { op(ctx) }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

for i in 0..<count {
    let scene = makeScene()
    render(scene, scale: 1, to: String(format: "%@/%05d_1x.png", out, i))
    render(scene, scale: 2, to: String(format: "%@/%05d_2x.png", out, i))
}
print("wrote \(count) pairs")
