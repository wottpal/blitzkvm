import AppKit
import CoreVideo
import JetKVMCore
import Metal
import ImageIO
import QuartzCore
import simd

/// Presents decoded NV12 pixel buffers with Metal, as soon as they arrive, on
/// a render queue of its own (the main thread never delays a frame).
///
/// The frame is converted to RGB at its own resolution (chroma upsampled with
/// Catmull-Rom at the position the stream declares), then scaled into the
/// drawable at physical (Retina) resolution: enlarged with AMD FSR 1 (EASU
/// edge-adaptive upscaling, then RCAS sharpening), which keeps 1× remote text
/// crisp without nearest-neighbor stair steps or bilinear blur; shrunk with a
/// widened Catmull-Rom (antialiased). "Exact Pixels" uses nearest-neighbor at
/// whole-number scales instead.
class VideoView: NSView {
    var scalingMode: ScalingMode {
        get { state.withLock { $0.mode } }
        set { state.withLock { $0.mode = newValue }; redraw() }
    }
    /// Nearest-neighbor at whole-number scales instead of FSR.
    var exactPixels: Bool {
        get { state.withLock { $0.exactPixels } }
        set { state.withLock { $0.exactPixels = newValue }; redraw() }
    }
    /// Which part of a video larger than the view is visible (0...1 per axis).
    var pan: (x: Double, y: Double) {
        get { state.withLock { $0.pan } }
        set {
            let changed = state.withLock { s -> Bool in
                guard s.pan != newValue else { return false }
                s.pan = newValue
                return true
            }
            if changed { redraw() }
        }
    }
    /// Latest layout in physical pixels, for pointer mapping.
    var layout: VideoLayout { state.withLock { $0.layout } }
    var presentedFrames: Int { state.withLock { $0.presented } }

    private struct State {
        var mode: ScalingMode = .actualSize
        var exactPixels = false
        var pan: (x: Double, y: Double) = (0.5, 0.5)
        var pointScale: Double = 2
        var drawableSize = CGSize.zero
        var layout = VideoLayout(x: 0, y: 0, width: 0, height: 0, nearest: false)
        var frame: CVPixelBuffer?
        var frameSerial: UInt64 = 0
        var renderPending = false
        var presented = 0
    }

    private let state = Locked(State())
    private let renderQueue = DispatchQueue(label: "jetkvm.render", qos: .userInteractive)
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var convertPipeline: MTLRenderPipelineState!
    private var scalePipeline: MTLRenderPipelineState!
    private var easuPipeline: MTLRenderPipelineState!
    private var rcasPipeline: MTLRenderPipelineState!
    private var linearClampSampler: MTLSamplerState!
    private var textureCache: CVMetalTextureCache?
    private let metalLayer = CAMetalLayer()
    // Render-queue state.
    private var rgbTexture: MTLTexture?
    /// Serial of the frame rgbTexture holds: redraws for a pan or resize
    /// reuse it. (Not the buffer's identity: VideoToolbox recycles buffers.)
    private var convertedSerial: UInt64 = 0
    /// EASU output, sized to the visible part of the scaled video.
    private var easuTexture: MTLTexture?
    /// RCAS strength in stops (0 = strongest). 0.5 sharpens text edges
    /// without a dark rim around light text on dark backgrounds.
    private static let rcasStops: Float = 0.5

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; };

    // rect = (x, y, w, h) in normalized device coordinates (origin bottom-left).
    vertex VOut quad_vertex(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
        float2 c = corners[vid];
        VOut out;
        out.position = float4(rect.x + c.x * rect.z, rect.y + c.y * rect.w, 0, 1);
        return out;
    }

    static float4 catmullRomWeights(float f) {
        float f2 = f * f, f3 = f2 * f;
        return float4(-0.5 * f3 + f2 - 0.5 * f,
                      1.5 * f3 - 2.5 * f2 + 1.0,
                      -1.5 * f3 + 2.0 * f2 + 0.5 * f,
                      0.5 * f3 - 0.5 * f2);
    }

    static float catmullRom(float x) {
        x = abs(x);
        if (x < 1.0) return (1.5 * x - 2.5) * x * x + 1.0;
        if (x < 2.0) return ((-0.5 * x + 2.5) * x - 4.0) * x + 2.0;
        return 0.0;
    }

    struct ConvertParams { float3x3 matrix; float3 offset; float2 chromaShift; };

    // Pass 1: NV12 → RGB at the source resolution.
    fragment float4 convert_fragment(VOut in [[stage_in]],
                                     texture2d<float, access::read> luma [[texture(0)]],
                                     texture2d<float, access::read> chroma [[texture(1)]],
                                     constant ConvertParams &p [[buffer(0)]]) {
        uint2 pos = uint2(in.position.xy);
        float y = luma.read(pos).r;
        int2 csize = int2(chroma.get_width(), chroma.get_height());
        // Continuous chroma index (texel i centered at i), shifted to where
        // the stream sites chroma relative to luma.
        float2 c = (float2(pos) + 0.5) * 0.5 + p.chromaShift - 0.5;
        float2 base = floor(c);
        float2 f = c - base;
        float4 wx = catmullRomWeights(f.x), wy = catmullRomWeights(f.y);
        int2 b = int2(base) - 1;
        float2 cbcr = 0;
        for (int j = 0; j < 4; j++) {
            float2 row = 0;
            for (int i = 0; i < 4; i++) {
                row += wx[i] * chroma.read(uint2(clamp(b + int2(i, j), int2(0), csize - 1))).rg;
            }
            cbcr += wy[j] * row;
        }
        float3 rgb = p.matrix * (float3(y, cbcr) - p.offset);
        return float4(saturate(rgb), 1.0);
    }

    struct ScaleParams { float2 origin; float2 scale; int filter; };

    static float4 texel(texture2d<float, access::read> t, int2 p, int2 size) {
        return t.read(uint2(clamp(p, int2(0), size - 1)));
    }

    // Pass 2: resample into the drawable.
    fragment float4 scale_fragment(VOut in [[stage_in]],
                                   texture2d<float, access::read> src [[texture(0)]],
                                   constant ScaleParams &p [[buffer(0)]]) {
        int2 size = int2(src.get_width(), src.get_height());
        float2 s = (in.position.xy - p.origin) / p.scale;   // texel i covers [i, i+1)
        if (p.filter == 0) {
            return texel(src, int2(floor(s)), size);
        }
        float2 center = s - 0.5;                            // texel i centered at i
        // Shrinking: Catmull-Rom widened by 1/scale averages every source
        // texel that falls into the output pixel (no aliasing, no shimmer).
        float2 widen = clamp(1.0 / p.scale, 1.0, 4.0);
        int2 lo = int2(ceil(center - 2.0 * widen));
        int2 hi = min(int2(floor(center + 2.0 * widen)), lo + 16);
        float wx[17];
        float sx = 0;
        for (int i = lo.x; i <= hi.x; i++) { wx[i - lo.x] = catmullRom((center.x - float(i)) / widen.x); sx += wx[i - lo.x]; }
        float4 sum = 0;
        float sy = 0;
        for (int j = lo.y; j <= hi.y; j++) {
            float wy = catmullRom((center.y - float(j)) / widen.y);
            if (wy == 0.0) continue;
            float4 row = 0;
            for (int i = lo.x; i <= hi.x; i++) row += wx[i - lo.x] * texel(src, int2(i, j), size);
            sum += wy * row;
            sy += wy;
        }
        return sum / (sx * sy);
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
        // Two drawables: one on screen, one being rendered. A third would
        // let frames queue up and add a refresh of latency.
        metalLayer.maximumDrawableCount = 2
        metalLayer.displaySyncEnabled = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        // The remote desktop's pixels are sRGB-encoded (the capture only
        // changes the matrix, not the transfer function). Tagging them sRGB
        // shows them as the remote Mac does; Rec.709 would wash them out.
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer = metalLayer
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        do {
            try buildPipelines()
        } catch {
            NSLog("Metal pipeline failed: \(error)")
            return nil
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    private func buildPipelines() throws {
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        func pipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "quad_vertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        convertPipeline = try pipeline("convert_fragment", .rgba16Float)
        scalePipeline = try pipeline("scale_fragment", metalLayer.pixelFormat)
        // FSR keeps upstream's code in a library of its own; exact resolve
        // keeps flat areas exactly flat (upstream darkens white by 0.2%).
        let options = MTLCompileOptions()
        options.preprocessorMacros = ["FSR_RCAS_EXACT_RESOLVE": NSNumber(value: 1)]
        let fsr = try device.makeLibrary(source: FSR.source, options: options)
        func fsrPipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = fsr.makeFunction(name: "fsr_rect_vertex")
            d.fragmentFunction = fsr.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        easuPipeline = try fsrPipeline("easu_fragment", .rgba16Float)
        rcasPipeline = try fsrPipeline("rcas_fragment", metalLayer.pixelFormat)
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        linearClampSampler = device.makeSamplerState(descriptor: sd)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    /// Backing scale factor of the screen the view is on.
    var pointScale: Double { state.withLock { $0.pointScale } }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        state.withLock {
            $0.pointScale = Double(scale)
            $0.drawableSize = size
        }
        redraw()
    }

    /// Hands a new decoded frame to the view. Frames that arrive faster than
    /// they can be drawn replace each other (newest wins).
    func display(_ pixelBuffer: CVPixelBuffer) {
        state.withLock {
            $0.frame = pixelBuffer
            $0.frameSerial &+= 1
        }
        redraw()
    }

    /// Schedules a render of the latest frame (coalesced).
    func redraw() {
        let schedule = state.withLock { s -> Bool in
            guard !s.renderPending else { return false }
            s.renderPending = true
            return true
        }
        if schedule {
            renderQueue.async { self.render() }
        }
    }

    private func render() {
        let s = state.withLock { s -> State in
            s.renderPending = false
            return s
        }
        guard s.drawableSize.width > 0, s.drawableSize.height > 0 else { return }
        if metalLayer.drawableSize != s.drawableSize {
            metalLayer.drawableSize = s.drawableSize
        }
        guard let drawable = metalLayer.nextDrawable(), let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let layout = encode(s, into: drawable.texture, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        state.withLock {
            if let layout { $0.layout = layout }
            if s.frame != nil { $0.presented += 1 }
        }
    }

    /// Encodes the frame into `target`; returns the layout used (nil without
    /// a frame).
    private func encode(_ s: State, into target: MTLTexture, commandBuffer: MTLCommandBuffer) -> VideoLayout? {
        let size = CGSize(width: target.width, height: target.height)
        var source: MTLTexture?
        if let frame = s.frame {
            if s.frameSerial == convertedSerial, let rgb = rgbTexture {
                source = rgb
            } else if let (luma, chroma) = textures(for: frame) {
                source = convert(frame: frame, luma: luma, chroma: chroma, commandBuffer: commandBuffer)
                convertedSerial = source == nil ? 0 : s.frameSerial
            }
        }
        var layout: VideoLayout?
        var draw: ((MTLRenderCommandEncoder) -> Void)?
        if let source {
            let l = VideoLayout.compute(videoWidth: source.width, videoHeight: source.height,
                                        drawableWidth: size.width, drawableHeight: size.height,
                                        mode: s.mode, pointScale: s.pointScale, pan: s.pan)
            layout = l
            // Only the visible part of the video rect (it overflows when
            // panning). Layout edges are whole pixels.
            let x0 = max(l.x, 0), y0 = max(l.y, 0)
            let x1 = min(l.x + l.width, size.width), y1 = min(l.y + l.height, size.height)
            if x1 > x0, y1 > y0 {
                // NDC has its origin bottom-left.
                var rect = SIMD4<Float>(Float(x0 / size.width * 2 - 1), Float(1 - y1 / size.height * 2),
                                        Float((x1 - x0) / size.width * 2), Float((y1 - y0) / size.height * 2))
                let scale = l.width / Double(source.width)
                let identity = abs(scale - 1) < 0.0001
                // Whole-multiple mode exists for exact pixels; elsewhere it is a preference.
                if scale >= 1 && !identity && !(l.nearest && (s.exactPixels || s.mode == .integer)),
                   let easu = easu(source: source, layout: l, visible: (x0, y0, x1, y1), commandBuffer: commandBuffer) {
                    var params = FSR.rcasConstants(sharpnessStops: Self.rcasStops, outputOrigin: SIMD2(Int32(x0), Int32(y0)))
                    draw = { encoder in
                        encoder.setRenderPipelineState(self.rcasPipeline)
                        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                        encoder.setFragmentTexture(easu, index: 0)
                        encoder.setFragmentBytes(&params, length: MemoryLayout<FSR.RcasParams>.stride, index: 0)
                        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    }
                } else {
                    // Nearest-neighbor at whole-number scales, otherwise shrinking.
                    var params = ScaleParams(origin: SIMD2(Float(l.x), Float(l.y)), scale: SIMD2(repeating: Float(scale)),
                                             filter: scale >= 1 ? 0 : 1)
                    draw = { encoder in
                        encoder.setRenderPipelineState(self.scalePipeline)
                        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                        encoder.setFragmentTexture(source, index: 0)
                        encoder.setFragmentBytes(&params, length: MemoryLayout<ScaleParams>.stride, index: 0)
                        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    }
                }
            }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        draw?(encoder)
        encoder.endEncoding()
        return layout
    }

    /// FSR EASU pass: upscales `source` into a texture holding the visible
    /// part of the scaled video (the RCAS pass then sharpens it into place).
    private func easu(source: MTLTexture, layout l: VideoLayout, visible: (Double, Double, Double, Double),
                      commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let (x0, y0, x1, y1) = visible
        let w = Int(x1 - x0), h = Int(y1 - y0)
        if easuTexture?.width != w || easuTexture?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            easuTexture = device.makeTexture(descriptor: d)
        }
        guard let out = easuTexture else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var rect = SIMD4<Float>(-1, -1, 2, 2)
        // The scaled image starts at (l.x - x0, l.y - y0) inside `out`.
        var params = FSR.easuConstants(inputSize: SIMD2(Float(source.width), Float(source.height)),
                                       outputSize: SIMD2(Float(l.width), Float(l.height)),
                                       outputOffset: SIMD2(Float(l.x - x0), Float(l.y - y0)))
        encoder.setRenderPipelineState(easuPipeline)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(linearClampSampler, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<FSR.EasuParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return out
    }

    /// Pass 1 into the (reused) RGB texture at the frame's size.
    private func convert(frame: CVPixelBuffer, luma: CVMetalTexture, chroma: CVMetalTexture, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
        if rgbTexture?.width != w || rgbTexture?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            rgbTexture = device.makeTexture(descriptor: d)
        }
        guard let rgb = rgbTexture else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = rgb
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var rect = SIMD4<Float>(-1, -1, 2, 2)
        var params = Self.colorParams(for: frame)
        encoder.setRenderPipelineState(convertPipeline)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(luma), index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(chroma), index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        // Keep the CVMetalTextures (and so the pixel buffer) alive until the
        // GPU is done.
        commandBuffer.addCompletedHandler { _ in _ = luma; _ = chroma }
        return rgb
    }

    /// Renders the current frame through the same pipeline into an offscreen
    /// texture of the drawable's size and writes a PNG (used by the self-test
    /// to verify color conversion and scaling).
    func writeSnapshot(to url: URL) -> Bool {
        renderQueue.sync {
            let s = state.withLock { $0 }
            let w = Int(s.drawableSize.width), h = Int(s.drawableSize.height)
            guard w > 0, h > 0, let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return false }
            _ = encode(s, into: texture, commandBuffer: commandBuffer)
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
        var chromaShift: SIMD2<Float>
    }

    struct ScaleParams {
        var origin: SIMD2<Float>
        var scale: SIMD2<Float>
        var filter: Int32
    }

    /// Video-range YCbCr → RGB, and where chroma sits relative to luma:
    /// H.264/H.265 default to "left" (horizontally on the even luma column,
    /// vertically between rows), half a luma pixel off from where a plain
    /// texture lookup would assume.
    ///
    /// The matrix is BT.601 whatever the stream declares: the JetKVM's HDMI
    /// bridge (TC358749, Linux tc358743 driver) always outputs BT.601
    /// limited-range YCbCr, while firmware 0.5.9 tags HD streams as BT.709.
    /// Measured against a known test image on the live device, BT.601 fits
    /// within 0.5 code values and BT.709 is off by 8 (saturated colors
    /// visibly wrong). JETKVM_COLOR_MATRIX=709 restores the declared matrix.
    static let forceBT601 = ProcessInfo.processInfo.environment["JETKVM_COLOR_MATRIX"] != "709"

    static func colorParams(for buffer: CVPixelBuffer) -> ColorParams {
        let matrixKey = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let height = CVPixelBufferGetHeight(buffer)
        let bt601 = forceBT601 || matrixKey == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) || (matrixKey == nil && height <= 576)
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
        let location = CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil) as? String
        return ColorParams(matrix: m, offset: SIMD3<Float>(16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0),
                           chromaShift: chromaShift(location: location))
    }

    /// Shift (in chroma texels) from a centered 2×2 chroma sample to the
    /// stream's chroma siting.
    static func chromaShift(location: String?) -> SIMD2<Float> {
        let shifts: [CFString: SIMD2<Float>] = [
            kCVImageBufferChromaLocation_Center: SIMD2(0, 0),
            kCVImageBufferChromaLocation_DV420: SIMD2(0, 0),
            kCVImageBufferChromaLocation_TopLeft: SIMD2(0.25, 0.25),
            kCVImageBufferChromaLocation_Top: SIMD2(0, 0.25),
            kCVImageBufferChromaLocation_BottomLeft: SIMD2(0.25, -0.25),
            kCVImageBufferChromaLocation_Bottom: SIMD2(0, -0.25),
        ]
        // Left, or unspecified: the H.264/H.265 default.
        return location.flatMap { shifts[$0 as CFString] } ?? SIMD2(0.25, 0)
    }

    /// The layout for the current state, before the next render applies it
    /// (pointer mapping must not lag a pan by a frame).
    /// Whether the video is larger than the view (so panning matters).
    var overflows: Bool {
        let l = currentLayout()
        let size = state.withLock { $0.drawableSize }
        return l.width > size.width + 0.5 || l.height > size.height + 0.5
    }

    func currentLayout() -> VideoLayout {
        state.withLock { s in
            guard let frame = s.frame else { return s.layout }
            return VideoLayout.compute(videoWidth: CVPixelBufferGetWidth(frame), videoHeight: CVPixelBufferGetHeight(frame),
                                       drawableWidth: s.drawableSize.width, drawableHeight: s.drawableSize.height,
                                       mode: s.mode, pointScale: s.pointScale, pan: s.pan)
        }
    }

    /// Size of the most recent frame in pixels.
    var currentVideoSize: CGSize? {
        state.withLock { s in
            s.frame.map { CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
        }
    }

    /// Converts a point in view coordinates to physical pixels (top-left
    /// origin), matching `layout`.
    func physicalPoint(_ point: NSPoint) -> (Double, Double) {
        let scale = Double(metalLayer.contentsScale)
        return (Double(point.x) * scale, Double(bounds.height - point.y) * scale)
    }
}

/// A value guarded by a lock.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
