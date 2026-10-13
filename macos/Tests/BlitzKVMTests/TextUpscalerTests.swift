import CoreGraphics
import ImageIO
import JetKVMCore
import Metal
import XCTest
@testable import BlitzKVM

/// The text upscaler on the GPU: its picture against the trained network's
/// reference, its tile gating, and the compose pass's footprint weights.
final class TextUpscalerTests: XCTestCase {
    func testComposeParams() {
        XCTAssertEqual(MemoryLayout<TextUpscaler.ComposeParams>.stride, 40)
        // Sub-pixels per axis a footprint can touch on the 3×3 grid.
        for (scale, taps) in [(1.25, 4), (1.5, 3), (2, 3), (2.5066667, 3), (3, 2)] as [(Double, Int32)] {
            let p = TextUpscaler.ComposeParams(origin: .zero, regionOrigin: .zero, frame: .zero, scale: SIMD2(repeating: scale), n: 3)
            XCTAssertEqual(p.taps, taps, "\(scale)×")
        }
    }

    /// The bundled weights at 2.5067× against PyTorch running the network
    /// they were exported from (half precision, the same area resampling):
    /// a 64×48 tile of 9–11 px text from the quality bench's test pattern.
    /// Metal and PyTorch differ by rounding only (63 dB on an M4 Max); a
    /// wrong sub-pixel order or phase scores 22–26 dB, a footprint one tap
    /// short 44 dB.
    func testMatchesTheTrainedNetwork() throws {
        let gpu = try GPU()
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let tile = try gpu.texture(png: fixtures.appendingPathComponent("text-tile.png"))
        let golden = try Data(contentsOf: fixtures.appendingPathComponent("text-tile-2.5067x-luma.u16")).withUnsafeBytes {
            $0.bindMemory(to: UInt16.self).map { Double(UInt16(littleEndian: $0)) / 65535 }
        }
        let upscaler = try XCTUnwrap(TextUpscaler(device: gpu.device))
        let out = try gpu.upscale(tile, with: upscaler, scale: 2.5066667, size: (160, 120))
        XCTAssertEqual(out.count / 4, golden.count)
        let luma: [Double] = stride(from: 0, to: out.count, by: 4).map { (i: Int) -> Double in
            let r: Double = 0.299 * Double(out[i]), g: Double = 0.587 * Double(out[i + 1]), b: Double = 0.114 * Double(out[i + 2])
            return r + g + b
        }
        let squaredErrors: [Double] = zip(luma, golden).map { (a: Double, b: Double) -> Double in (a - b) * (a - b) }
        let mse = squaredErrors.reduce(0, +) / Double(golden.count)
        let psnr = 10 * log10(1 / mse)
        XCTAssertGreaterThan(psnr, 55, "luma PSNR against the reference")
    }

    /// The network compares only the tiles the caller marks dirty and
    /// recomputes those that changed and their neighbors: an update must
    /// equal a run from scratch, bit for bit.
    func testTileGatedUpdateMatchesAFreshRun() throws {
        let gpu = try GPU()
        var random = SplitMix64(seed: 5)
        let (w, h) = (160, 96)
        var pixels = (0..<w * h).flatMap { _ -> [Float16] in
            let v = Float16(Float(random.next() % 256) / 255)
            return [v, v, v, 1]
        }
        let a = try gpu.texture(width: w, height: h, rgba: pixels)
        // A word typed just past a corner of the 16×16 tiles: the tiles
        // above and to the left change too, without changes of their own.
        let word = PixelRect(x0: 66, y0: 34, x1: 90, y1: 46)
        for y in word.y0..<word.y1 {
            for x in word.x0..<word.x1 { pixels[(y * w + x) * 4 + 1] = Float16(Float(random.next() % 256) / 255) }
        }
        let b = try gpu.texture(width: w, height: h, rgba: pixels)
        let updated = try XCTUnwrap(TextUpscaler(device: gpu.device)), fresh = try XCTUnwrap(TextUpscaler(device: gpu.device))
        _ = try gpu.upscale(a, with: updated, scale: 2.5, size: (400, 240))
        let update = try gpu.upscale(b, with: updated, dirty: word, scale: 2.5, size: (400, 240))
        let differing = { (other: [Float16]) in zip(update, other).filter { $0 != $1 }.count }
        XCTAssertEqual(differing(try gpu.upscale(b, with: fresh, scale: 2.5, size: (400, 240))), 0, "values that differ from a fresh run")
        // Nothing changed: nothing recomputed, the same picture.
        XCTAssertEqual(differing(try gpu.upscale(b, with: updated, dirty: .empty, scale: 2.5, size: (400, 240))), 0, "values that changed")
        XCTAssertEqual(differing(try gpu.upscale(b, with: updated, scale: 2.5, size: (400, 240))), 0, "values that changed")
    }

    /// A changed source pixel changes the picture only within `margin` source
    /// pixels (the network's receptive field, then a footprint): VideoView
    /// computes the network's region and redraws changes with that reach.
    func testChangeReachesNoFurtherThanTheMargin() throws {
        let gpu = try GPU()
        var random = SplitMix64(seed: 7)
        let (w, h, scale) = (64, 48, 2.5)
        var pixels = (0..<w * h).flatMap { _ -> [Float16] in
            let v = Float16(Float(random.next() % 256) / 255)
            return [v, v, v, 1]
        }
        let a = try gpu.texture(width: w, height: h, rgba: pixels)
        let (cx, cy) = (30, 20)
        pixels[(cy * w + cx) * 4] = 1 - pixels[(cy * w + cx) * 4]
        let b = try gpu.texture(width: w, height: h, rgba: pixels)
        let size = (Int(Double(w) * scale), Int(Double(h) * scale))
        let before = try gpu.upscale(a, with: XCTUnwrap(TextUpscaler(device: gpu.device)), scale: scale, size: size)
        let after = try gpu.upscale(b, with: XCTUnwrap(TextUpscaler(device: gpu.device)), scale: scale, size: size)
        // How far the changed output pixels' centers lie from the changed
        // source pixel's, in source pixels (Chebyshev).
        var reach = 0.0
        for y in 0..<size.1 {
            for x in 0..<size.0 where before[(y * size.0 + x) * 4] != after[(y * size.0 + x) * 4] {
                let dx = abs((Double(x) + 0.5) / scale - (Double(cx) + 0.5)), dy = abs((Double(y) + 0.5) / scale - (Double(cy) + 0.5))
                reach = max(reach, dx, dy)
            }
        }
        XCTAssertGreaterThan(reach, 4, "beyond other filters' reach")
        XCTAssertLessThanOrEqual(reach, Double(TextUpscaler.margin))
    }

    /// Each output pixel's detail is the mean of the sub-pixels under its
    /// footprint: the weights sum to one at any scale and phase, also where
    /// the footprint reaches beyond the frame.
    func testFootprintWeightsSumToOne() throws {
        let gpu = try GPU()
        let upscaler = try XCTUnwrap(TextUpscaler(device: gpu.device))
        let (w, h) = (37, 23)
        let black = try gpu.texture(width: w, height: h, rgba: [Float16](repeating: 0, count: w * h * 4))
        let detail = try gpu.detail(width: w * upscaler.n, height: h * upscaler.n) { _, _ in 0.5 }
        var random = SplitMix64(seed: 9)
        for _ in 0..<20 {
            let scale = SIMD2(1 + 2 * Double(random.next() % 10_000) / 10_000, 1 + 2 * Double(random.next() % 10_000) / 10_000)
            let size = (Int((Double(w) * scale.x).rounded()), Int((Double(h) * scale.y).rounded()))
            let out = try gpu.compose(upscaler, rgb: black, detail: detail, scale: scale, size: size)
            let worst = stride(from: 0, to: out.count, by: 4).map { abs(Float(out[$0]) - 0.5) }.max() ?? 0
            XCTAssertLessThan(worst, 0.001, "at \(scale)")
        }
    }

    /// At a scale of exactly n, each output pixel is its own sub-pixel. With
    /// n = 2 at 2×, that is the compose pass of the earlier 2× upscaler.
    func testWholeScaleTakesOneSubPixel() throws {
        let gpu = try GPU()
        let zeros = { (count: Int) in [Float](repeating: 0, count: count) }
        let twoByTwo = TextUpscaler.Weights(n: 2, c1: zeros(200), b1: zeros(8), c2: zeros(576), b2: zeros(8),
                                            c3: zeros(576), b3: zeros(8), c4: zeros(288), b4: zeros(4))
        for weights in [twoByTwo, .bundled] {
            let upscaler = try XCTUnwrap(TextUpscaler(device: gpu.device, weights: weights))
            let n = upscaler.n, (w, h) = (29, 17)
            let value = { (x: Int, y: Int) in Float16(Float((x * 7 + y * 13) % 97) / 128) }
            let black = try gpu.texture(width: w, height: h, rgba: [Float16](repeating: 0, count: w * h * 4))
            let detail = try gpu.detail(width: w * n, height: h * n, value)
            let out = try gpu.compose(upscaler, rgb: black, detail: detail, scale: SIMD2(repeating: Double(n)), size: (w * n, h * n))
            let wrong = (0..<h * n).flatMap { y in (0..<w * n).map { (x: $0, y: y) } }.filter { out[($0.y * w * n + $0.x) * 4] != value($0.x, $0.y) }
            XCTAssertEqual(wrong.count, 0, "n = \(n): first at \(wrong.first.map { "(\($0.x), \($0.y))" } ?? "")")
        }
    }
}

/// Runs the upscaler and its compose pass into rgba16Float textures.
private struct GPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let vertex: MTLFunction
    let sampler: MTLSamplerState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        self.device = device
        queue = try XCTUnwrap(device.makeCommandQueue())
        // VideoView's quad vertex function.
        let library = try device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            struct VOut { float4 position [[position]]; };
            vertex VOut quad_vertex(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
                float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
                VOut out;
                out.position = float4(rect.x + corners[vid].x * rect.z, rect.y + corners[vid].y * rect.w, 0, 1);
                return out;
            }
            """, options: nil)
        vertex = try XCTUnwrap(library.makeFunction(name: "quad_vertex"))
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = try XCTUnwrap(device.makeSamplerState(descriptor: sd))
    }

    func texture(width: Int, height: Int, rgba: [Float16]) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .shared
        let t = try XCTUnwrap(device.makeTexture(descriptor: d))
        rgba.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        return t
    }

    /// An sRGB PNG as the converted frame holds it (8-bit values, not linearized).
    func texture(png url: URL) throws -> MTLTexture {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return try texture(width: w, height: h, rgba: bytes.map { Float16(Float($0) / 255) })
    }

    /// A detail image (one half-float sub-pixel per texel).
    func detail(width: Int, height: Int, _ value: (Int, Int) -> Float16) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        let t = try XCTUnwrap(device.makeTexture(descriptor: d))
        let values = (0..<height).flatMap { y in (0..<width).map { value($0, y) } }
        values.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 2) }
        return t
    }

    /// The network over all of `rgb` (`dirty` where it may have changed),
    /// then the compose pass.
    func upscale(_ rgb: MTLTexture, with upscaler: TextUpscaler, dirty: PixelRect? = nil, scale: Double, size: (Int, Int)) throws -> [Float16] {
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let detail = try XCTUnwrap(upscaler.encode(rgb: rgb, origin: .zero, width: rgb.width, height: rgb.height, dirty: dirty,
                                                   commandBuffer: commandBuffer))
        return try compose(upscaler, rgb: rgb, detail: detail, scale: SIMD2(repeating: scale), size: size, after: commandBuffer)
    }

    func compose(_ upscaler: TextUpscaler, rgb: MTLTexture, detail: MTLTexture, scale: SIMD2<Double>, size: (Int, Int),
                 after network: MTLCommandBuffer? = nil) throws -> [Float16] {
        let commandBuffer = try network ?? XCTUnwrap(queue.makeCommandBuffer())
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vertex
        d.fragmentFunction = upscaler.composeFunction
        d.colorAttachments[0].pixelFormat = .rgba16Float
        let pipeline = try device.makeRenderPipelineState(descriptor: d)
        let out = try texture(width: size.0, height: size.1, rgba: [Float16](repeating: 0, count: size.0 * size.1 * 4))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        var rect = SIMD4<Float>(-1, -1, 2, 2)
        var params = TextUpscaler.ComposeParams(origin: .zero, regionOrigin: .zero, frame: SIMD2(Int32(rgb.width), Int32(rgb.height)),
                                                scale: scale, n: upscaler.n)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(rgb, index: 0)
        encoder.setFragmentTexture(detail, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<TextUpscaler.ComposeParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var pixels = [Float16](repeating: 0, count: size.0 * size.1 * 4)
        pixels.withUnsafeMutableBytes { out.getBytes($0.baseAddress!, bytesPerRow: size.0 * 8, from: MTLRegionMake2D(0, 0, size.0, size.1), mipmapLevel: 0) }
        return pixels
    }
}
