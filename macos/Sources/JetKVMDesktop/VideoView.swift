import AppKit
import CoreVideo
import JetKVMCore
import Metal
import ImageIO
import QuartzCore
import simd

/// Presents decoded NV12 pixel buffers with Metal: zero-copy textures via
/// CVMetalTextureCache, YCbCr→RGB with the matrix the stream declares
/// (BT.709 or BT.601), drawn at physical (Retina) resolution as soon as a
/// frame arrives.
class VideoView: NSView {
    var scalingMode: ScalingMode = .fit { didSet { redraw() } }
    /// Latest layout in physical pixels, for pointer mapping.
    private(set) var layout = VideoLayout(x: 0, y: 0, width: 0, height: 0, nearest: false)
    private(set) var presentedFrames = 0
    var onPresent: ((CVPixelBuffer) -> Void)?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState!
    private var linearSampler: MTLSamplerState!
    private var nearestSampler: MTLSamplerState!
    private var textureCache: CVMetalTextureCache?
    private let metalLayer = CAMetalLayer()
    private let frameLock = NSLock()
    private var currentFrame: CVPixelBuffer?
    private var pendingDraw = false

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 uv; };

    // rect = (x, y, w, h) in normalized device coordinates (origin bottom-left).
    vertex VOut video_vertex(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
        float2 c = corners[vid];
        VOut out;
        out.position = float4(rect.x + c.x * rect.z, rect.y + c.y * rect.w, 0, 1);
        out.uv = float2(c.x, 1 - c.y);
        return out;
    }

    struct ColorParams { float3x3 matrix; float3 offset; };

    fragment float4 video_fragment(VOut in [[stage_in]],
                                   texture2d<float> luma [[texture(0)]],
                                   texture2d<float> chroma [[texture(1)]],
                                   sampler s [[sampler(0)]],
                                   constant ColorParams &params [[buffer(0)]]) {
        float3 ycbcr = float3(luma.sample(s, in.uv).r, chroma.sample(s, in.uv).rg);
        float3 rgb = params.matrix * (ycbcr - params.offset);
        return float4(saturate(rgb), 1);
    }
    """

    init?(frame: NSRect, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        // Two drawables: one on screen, one being rendered. Fewer queued
        // frames means less latency.
        metalLayer.maximumDrawableCount = 2
        metalLayer.displaySyncEnabled = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        do {
            try buildPipeline()
        } catch {
            NSLog("Metal pipeline failed: \(error)")
            return nil
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    private func buildPipeline() throws {
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "video_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "video_fragment")
        descriptor.colorAttachments[0].pixelFormat = metalLayer.pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        linearSampler = device.makeSamplerState(descriptor: s)
        s.minFilter = .nearest
        s.magFilter = .nearest
        nearestSampler = device.makeSamplerState(descriptor: s)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        redraw()
    }

    /// Hands a new decoded frame to the view; drawn on the main thread at the
    /// next opportunity (frames that arrive faster than they can be drawn
    /// replace each other — newest wins).
    func display(_ pixelBuffer: CVPixelBuffer) {
        frameLock.lock()
        currentFrame = pixelBuffer
        let schedule = !pendingDraw
        pendingDraw = true
        frameLock.unlock()
        if schedule {
            DispatchQueue.main.async { self.drawPending() }
        }
    }

    private func drawPending() {
        frameLock.lock()
        pendingDraw = false
        frameLock.unlock()
        redraw()
    }

    func redraw() {
        frameLock.lock()
        let frame = currentFrame
        frameLock.unlock()
        guard let drawable = metalLayer.nextDrawable(), let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        layout = encode(frame: frame, into: drawable.texture, size: metalLayer.drawableSize, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        if let frame {
            presentedFrames += 1
            onPresent?(frame)
        }
    }

    /// Encodes one frame into target; returns the layout used.
    @discardableResult
    private func encode(frame: CVPixelBuffer?, into target: MTLTexture, size: CGSize, commandBuffer: MTLCommandBuffer) -> VideoLayout {
        var result = layout
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return result }
        if let frame, let (luma, chroma) = textures(for: frame) {
            let l = VideoLayout.compute(videoWidth: CVPixelBufferGetWidth(frame), videoHeight: CVPixelBufferGetHeight(frame),
                                        drawableWidth: size.width, drawableHeight: size.height, mode: scalingMode)
            result = l
            // Pixel rect (top-left origin) → NDC (bottom-left origin).
            var rect = SIMD4<Float>(
                Float(l.x / size.width * 2 - 1),
                Float(1 - (l.y + l.height) / size.height * 2),
                Float(l.width / size.width * 2),
                Float(l.height / size.height * 2))
            var params = Self.colorParams(for: frame)
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(luma), index: 0)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(chroma), index: 1)
            encoder.setFragmentSamplerState(l.nearest ? nearestSampler : linearSampler, index: 0)
            encoder.setFragmentBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            // Keep the CVMetalTextures alive until the GPU is done.
            commandBuffer.addCompletedHandler { _ in _ = luma; _ = chroma }
        }
        encoder.endEncoding()
        return result
    }

    /// Renders the current frame through the same pipeline into an offscreen
    /// texture of the drawable's size and writes a PNG (used by the self-test
    /// to verify color conversion and scaling).
    func writeSnapshot(to url: URL) -> Bool {
        frameLock.lock()
        let frame = currentFrame
        frameLock.unlock()
        let size = metalLayer.drawableSize
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return false }
        encode(frame: frame, into: texture, size: size, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private func textures(for buffer: CVPixelBuffer) -> (CVMetalTexture, CVMetalTexture)? {
        guard let cache = textureCache, CVPixelBufferGetPlaneCount(buffer) == 2 else { return nil }
        func plane(_ index: Int, _ format: MTLPixelFormat) -> CVMetalTexture? {
            var texture: CVMetalTexture?
            let w = CVPixelBufferGetWidthOfPlane(buffer, index)
            let h = CVPixelBufferGetHeightOfPlane(buffer, index)
            let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, format, w, h, index, &texture)
            return status == kCVReturnSuccess ? texture : nil
        }
        guard let luma = plane(0, .r8Unorm), let chroma = plane(1, .rg8Unorm) else { return nil }
        return (luma, chroma)
    }

    struct ColorParams {
        var matrix: simd_float3x3
        var offset: SIMD3<Float>
    }

    /// Video-range YCbCr → RGB for the matrix the stream declares. The
    /// device encodes HD modes as BT.709 and SD modes (≤576 lines) as BT.601.
    static func colorParams(for buffer: CVPixelBuffer) -> ColorParams {
        let matrixKey = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let height = CVPixelBufferGetHeight(buffer)
        let bt601 = matrixKey == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) || (matrixKey == nil && height <= 576)
        let (kr, kb): (Float, Float) = bt601 ? (0.299, 0.114) : (0.2126, 0.0722)
        let kg = 1 - kr - kb
        // Expand video range (Y 16–235, C 16–240) to full range.
        let ys: Float = 255.0 / 219.0
        let cs: Float = 255.0 / 224.0
        let crR = 2 * (1 - kr)
        let cbB = 2 * (1 - kb)
        let cbG = -2 * kb * (1 - kb) / kg
        let crG = -2 * kr * (1 - kr) / kg
        let m = simd_float3x3(columns: (
            SIMD3<Float>(ys, ys, ys),
            SIMD3<Float>(0, cbG * cs, cbB * cs),
            SIMD3<Float>(crR * cs, crG * cs, 0)))
        return ColorParams(matrix: m, offset: SIMD3<Float>(16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0))
    }

    /// Size of the most recent frame in pixels.
    var currentVideoSize: CGSize? {
        frameLock.lock()
        defer { frameLock.unlock() }
        guard let frame = currentFrame else { return nil }
        return CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
    }

    /// Converts a point in view coordinates to physical pixels (top-left
    /// origin), matching `layout`.
    func physicalPoint(_ point: NSPoint) -> (Double, Double) {
        let scale = Double(metalLayer.contentsScale)
        return (Double(point.x) * scale, Double(bounds.height - point.y) * scale)
    }
}
