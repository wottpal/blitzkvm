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
/// The frame is converted to RGB at its own resolution (chroma reconstructed
/// guided by luma, Catmull-Rom where that does not fit), then scaled into a 10-bit
/// drawable at physical (Retina) resolution. Enlarged by exactly 2× (Actual
/// Size on Retina), the picture goes through the learned text upscaler
/// (TextUpscaler.swift); other enlargements use AMD FSR 1 (EASU edge-adaptive
/// upscaling, then RCAS sharpening), which keeps 1× remote text crisp without
/// nearest-neighbor stair steps or bilinear blur. Shrinking uses a widened
/// Catmull-Rom (antialiased). "Exact Pixels" uses nearest-neighbor at
/// whole-number scales instead.
class VideoView: NSView {
    var scalingMode: ScalingMode {
        get { state.withLock { $0.mode } }
        set { state.withLock { $0.mode = newValue }; redraw() }
    }
    /// Match Window: window points per remote pixel (Device.matchScale).
    var matchScale: Double {
        get { state.withLock { $0.matchScale } }
        set { state.withLock { $0.matchScale = newValue }; redraw() }
    }
    /// How enlargements are resampled (View › Scaling Filter).
    var scalingFilter: ScalingFilter {
        get { state.withLock { $0.filter } }
        set { state.withLock { $0.filter = newValue }; redraw() }
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
    /// Frames identical to the one on screen, which were not drawn again.
    var unchangedFrames: Int { state.withLock { $0.unchanged } }

    private struct State {
        var mode: ScalingMode = .actualSize
        var exactPixels = false
        var filter = ScalingFilter.automatic
        var matchScale: Double = 1
        var pan: (x: Double, y: Double) = (0.5, 0.5)
        var pointScale: Double = 2
        var drawableSize = CGSize.zero
        var layout = VideoLayout(x: 0, y: 0, width: 0, height: 0, nearest: false)
        var frame: CVPixelBuffer?
        var frameSerial: UInt64 = 0
        var renderPending = false
        var presented = 0
        var unchanged = 0
        /// The last frame went through the text upscaler.
        var textUpscaling = false
    }

    private let state = Locked(State())
    private let renderQueue = DispatchQueue(label: "jetkvm.render", qos: .userInteractive)
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var convertPipeline: MTLRenderPipelineState!
    private var scalePipeline: MTLRenderPipelineState!
    private var easuPipeline: MTLRenderPipelineState!
    private var rcasPipeline: MTLRenderPipelineState!
    private var compose2xPipeline: MTLRenderPipelineState!
    private lazy var textUpscaler = TextUpscaler(device: device)
    private var chromaSitedPipeline: MTLComputePipelineState!
    private var chromaFitPipeline: MTLComputePipelineState!
    private var chromaFitMeanPipeline: MTLComputePipelineState!
    private var chromaResidualPipeline: MTLComputePipelineState!
    /// Half-resolution intermediates of the guided chroma (see the shader).
    private var chromaTextures: (sited: MTLTexture, fit: MTLTexture, fitMean: MTLTexture, residual: MTLTexture)?
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
    /// BLITZKVM_RCAS_STOPS overrides it (A/B checks).
    private static let rcasStops = Float(ProcessInfo.processInfo.environment["BLITZKVM_RCAS_STOPS"] ?? "") ?? 0.5
    /// BLITZKVM_UPSCALER=fsr uses FSR at 2× too, =catmull enlarges with
    /// Catmull-Rom instead of FSR (A/B checks).
    private static let fsrUpscaling = ProcessInfo.processInfo.environment["BLITZKVM_UPSCALER"] != "catmull"
    private static let textUpscaling = fsrUpscaling && ProcessInfo.processInfo.environment["BLITZKVM_UPSCALER"] != "fsr"

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

    struct ConvertParams { float3x3 matrix; float3 offset; float2 chromaShift; int guided; float lumaBias; };

    // Continuous chroma index (texel i centered at i) of a luma pixel,
    // shifted to where the stream sites chroma relative to luma.
    static float2 chromaCoord(int2 pos, float2 shift) {
        return (float2(pos) + 0.5) * 0.5 + shift - 0.5;
    }

    static float4 catmullRomRG(texture2d<float, access::read> t, float2 c) {
        int2 size = int2(t.get_width(), t.get_height());
        float2 base = floor(c);
        float2 f = c - base;
        float4 wx = catmullRomWeights(f.x), wy = catmullRomWeights(f.y);
        int2 b = int2(base) - 1;
        float4 sum = 0;
        for (int j = 0; j < 4; j++) {
            float4 row = 0;
            for (int i = 0; i < 4; i++) {
                row += wx[i] * t.read(uint2(clamp(b + int2(i, j), int2(0), size - 1)));
            }
            sum += wy[j] * row;
        }
        return sum;
    }

    // Luma-guided chroma ("chroma from luma"). Inside a few pixels, desktop
    // content mixes two colors (antialiased text on a background), so chroma
    // is a linear function of luma there. Each chroma site fits
    // chroma = a * luma + b over its 3x3 neighbourhood (luma filtered the way
    // the JetKVM subsamples chroma); the full-resolution luma then puts the
    // chroma edges back where the luma edges are. A back-projection step
    // keeps the result consistent with the transmitted chroma where the model
    // does not hold (photos). Measured on device frames: colored text
    // 28 -> 46 dB at QP 10, 51 dB on a still refresh; no region worse than
    // 0.4 dB (plan section 23).
    //
    // The JetKVM's 4:2:0 chroma: horizontal [1 2 1]/4 centered on even
    // columns, the average of two rows ("left" siting).
    static float sitedLuma(texture2d<float, access::read> luma, int2 site) {
        int2 size = int2(luma.get_width(), luma.get_height());
        float sum = 0;
        for (int r = 0; r < 2; r++) {
            int y = min(site.y * 2 + r, size.y - 1);
            int x = site.x * 2;
            sum += 0.25 * luma.read(uint2(max(x - 1, 0), y)).r + 0.5 * luma.read(uint2(min(x, size.x - 1), y)).r
                 + 0.25 * luma.read(uint2(min(x + 1, size.x - 1), y)).r;
        }
        return sum * 0.5;
    }

    kernel void chroma_sited_luma(texture2d<float, access::read> luma [[texture(0)]],
                                  texture2d<float, access::write> out [[texture(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        out.write(float4(sitedLuma(luma, int2(gid))), gid);
    }

    // Per chroma site: a (cb, cr) and b (cb, cr) of the local linear fit.
    kernel void chroma_fit(texture2d<float, access::read> sited [[texture(0)]],
                           texture2d<float, access::read> chroma [[texture(1)]],
                           texture2d<float, access::write> out [[texture(2)]],
                           constant float &eps [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        int2 size = int2(out.get_width(), out.get_height());
        if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
        float sy = 0, syy = 0;
        float2 sc = 0, syc = 0;
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                uint2 q = uint2(clamp(int2(gid) + int2(i, j), int2(0), size - 1));
                float y = sited.read(q).r;
                float2 c = chroma.read(q).rg;
                sy += y; syy += y * y; sc += c; syc += y * c;
            }
        }
        float my = sy / 9.0, vy = max(syy / 9.0 - my * my, 0.0);
        float2 mc = sc / 9.0, cov = syc / 9.0 - my * mc;
        float2 a = cov / (vy + eps);
        out.write(float4(a, mc - a * my), gid);
    }

    // 3x3 mean of the fits (each pixel is covered by several windows).
    kernel void chroma_fit_mean(texture2d<float, access::read> fit [[texture(0)]],
                                texture2d<float, access::write> out [[texture(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
        int2 size = int2(out.get_width(), out.get_height());
        if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
        float4 sum = 0;
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                sum += fit.read(uint2(clamp(int2(gid) + int2(i, j), int2(0), size - 1)));
            }
        }
        out.write(sum / 9.0, gid);
    }

    // The fit's chroma for one luma pixel: (a, b) interpolated bilinearly at
    // the pixel's chroma position.
    static float2 fittedChroma(texture2d<float, access::read> fit, texture2d<float, access::read> luma,
                               int2 pos, float2 shift) {
        int2 size = int2(fit.get_width(), fit.get_height());
        float2 c = chromaCoord(pos, shift);
        float2 base = floor(c);
        float2 f = c - base;
        int2 b0 = clamp(int2(base), int2(0), size - 1), b1 = clamp(int2(base) + 1, int2(0), size - 1);
        float4 v = mix(mix(fit.read(uint2(b0.x, b0.y)), fit.read(uint2(b1.x, b0.y)), f.x),
                       mix(fit.read(uint2(b0.x, b1.y)), fit.read(uint2(b1.x, b1.y)), f.x), f.y);
        int2 lsize = int2(luma.get_width(), luma.get_height());
        float y = luma.read(uint2(clamp(pos, int2(0), lsize - 1))).r;
        return v.xy * y + v.zw;
    }

    // Back-projection: transmitted chroma minus the fit's chroma subsampled
    // the way the device subsamples.
    kernel void chroma_residual(texture2d<float, access::read> fit [[texture(0)]],
                                texture2d<float, access::read> luma [[texture(1)]],
                                texture2d<float, access::read> chroma [[texture(2)]],
                                texture2d<float, access::write> out [[texture(3)]],
                                constant float2 &shift [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        int2 lsize = int2(luma.get_width(), luma.get_height());
        float2 sum = 0;
        for (int r = 0; r < 2; r++) {
            int y = min(int(gid.y) * 2 + r, lsize.y - 1);
            int x = int(gid.x) * 2;
            sum += 0.25 * fittedChroma(fit, luma, int2(max(x - 1, 0), y), shift)
                 + 0.5 * fittedChroma(fit, luma, int2(min(x, lsize.x - 1), y), shift)
                 + 0.25 * fittedChroma(fit, luma, int2(min(x + 1, lsize.x - 1), y), shift);
        }
        out.write(float4(chroma.read(gid).rg - sum * 0.5, 0, 0), gid);
    }

    // Pass 1: NV12 → RGB at the source resolution. Chroma is either the
    // guided fit plus the Catmull-Rom-upsampled residual, or plain
    // Catmull-Rom.
    fragment float4 convert_fragment(VOut in [[stage_in]],
                                     texture2d<float, access::read> luma [[texture(0)]],
                                     texture2d<float, access::read> chroma [[texture(1)]],
                                     texture2d<float, access::read> fit [[texture(2)]],
                                     texture2d<float, access::read> residual [[texture(3)]],
                                     constant ConvertParams &p [[buffer(0)]]) {
        int2 pos = int2(in.position.xy);
        float y = luma.read(uint2(pos)).r;
        // The JetKVM's HDMI bridge truncates luma instead of rounding it
        // (measured on a gray ramp: every step decodes 0-1 code values low,
        // 0.5 on average). Half a code value puts it back in the middle;
        // exact black (16) gets nothing, so it stays black.
        y += p.lumaBias * saturate(y * 255.0 - 16.0);
        float2 c = chromaCoord(pos, p.chromaShift);
        float2 cbcr = p.guided != 0 ? fittedChroma(fit, luma, pos, p.chromaShift) + catmullRomRG(residual, c).rg
                                    : catmullRomRG(chroma, c).rg;
        float3 rgb = p.matrix * (float3(y, cbcr) - p.offset);
        return float4(saturate(rgb), 1.0);
    }

    struct ComposeParams { float2 origin; int2 regionOrigin; };

    // Exactly 2x with the text upscaler (TextUpscaler.swift): bilinear RGB
    // plus the network's sub-pixel luma detail on every channel (luma
    // changes, chroma stays).
    fragment float4 compose2x_fragment(VOut in [[stage_in]],
                                       texture2d<float> rgb [[texture(0)]],
                                       texture2d<half, access::read> detail [[texture(1)]],
                                       sampler s [[sampler(0)]],
                                       constant ComposeParams &p [[buffer(0)]]) {
        float2 d = in.position.xy - p.origin;
        float3 c = rgb.sample(s, d * 0.5 / float2(rgb.get_width(), rgb.get_height())).rgb;
        int2 sub = int2(floor(d)) & 1;
        float r = float(detail.read(uint2(int2(floor(d * 0.5)) - p.regionOrigin))[sub.y * 2 + sub.x]);
        return float4(saturate(c + r), 1.0);
    }

    // filter: 0 nearest, 1 Catmull-Rom, 2 Lanczos-3, 3 bilinear, 4 sharp
    // bilinear (area-weighted nearest).
    struct ScaleParams { float2 origin; float2 scale; int filter; };

    static float lanczos3(float x) {
        x = abs(x);
        if (x < 1e-5) return 1.0;
        if (x >= 3.0) return 0.0;
        float px = M_PI_F * x;
        return 3.0 * sin(px) * sin(px / 3.0) / (px * px);
    }

    static float kernelWeight(int filter, float x) {
        if (filter == 2) return lanczos3(x);
        if (filter == 3) return max(0.0, 1.0 - abs(x));
        return catmullRom(x);
    }

    static float kernelRadius(int filter) {
        return filter == 2 ? 3.0 : (filter == 3 ? 1.0 : 2.0);
    }

    // The two texels an output pixel's footprint (width 1/scale, at most one
    // texel when enlarging) overlaps, and the share of the first.
    static void areaTaps(float s, float halfWidth, thread int &i0, thread float &w0) {
        float lo = s - halfWidth, hi = s + halfWidth;
        i0 = int(floor(lo));
        float boundary = float(i0 + 1);
        w0 = hi <= boundary ? 1.0 : (boundary - lo) / (hi - lo);
    }

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
        int filter = p.filter;
        if (filter == 4) {
            if (all(p.scale >= 1.0)) {
                int ix, iy;
                float wx0, wy0;
                areaTaps(s.x, 0.5 / p.scale.x, ix, wx0);
                areaTaps(s.y, 0.5 / p.scale.y, iy, wy0);
                float4 top = mix(texel(src, int2(ix + 1, iy), size), texel(src, int2(ix, iy), size), wx0);
                float4 bottom = mix(texel(src, int2(ix + 1, iy + 1), size), texel(src, int2(ix, iy + 1), size), wx0);
                return mix(bottom, top, wy0);
            }
            filter = 1; // shrinking: antialiased like the others
        }
        float2 center = s - 0.5;                            // texel i centered at i
        // Shrinking: the kernel widened by 1/scale averages every source
        // texel that falls into the output pixel (no aliasing, no shimmer).
        float radius = kernelRadius(filter);
        float2 widen = clamp(1.0 / p.scale, 1.0, 12.0 / radius);
        int2 lo = int2(ceil(center - radius * widen));
        int2 hi = min(int2(floor(center + radius * widen)), lo + 24);
        float wx[25];
        float sx = 0;
        for (int i = lo.x; i <= hi.x; i++) { wx[i - lo.x] = kernelWeight(filter, (center.x - float(i)) / widen.x); sx += wx[i - lo.x]; }
        float4 sum = 0;
        float sy = 0;
        for (int j = lo.y; j <= hi.y; j++) {
            float wy = kernelWeight(filter, (center.y - float(j)) / widen.y);
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
        // 10 bits per channel: the picture is computed in floating point,
        // and 8-bit output would add a rounding step of its own (uneven
        // steps in gradients, since video range expands 219 levels to 255).
        // The compositor dithers it to the panel.
        metalLayer.pixelFormat = .bgr10a2Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        // Two drawables: one on screen, one being rendered. A third would
        // let frames queue up and add a refresh of latency.
        metalLayer.maximumDrawableCount = 2
        // Without display sync, a frame goes to the window server as soon as
        // the GPU is done; it still flips at vblank and keeps only the newest
        // frame (no tearing: present times jump by whole refreshes, never land
        // mid-scan). With display sync, each present waits for our own next
        // vsync and holds a drawable for a refresh. Measured from decode to
        // screen at 60 Hz: 52 -> 18 ms in a window, 48 -> 7 ms in full
        // screen. BLITZKVM_DISPLAY_SYNC=1 turns it back on (A/B).
        metalLayer.displaySyncEnabled = ProcessInfo.processInfo.environment["BLITZKVM_DISPLAY_SYNC"] == "1"
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
        func kernel(_ name: String) throws -> MTLComputePipelineState {
            try device.makeComputePipelineState(function: library.makeFunction(name: name)!)
        }
        chromaSitedPipeline = try kernel("chroma_sited_luma")
        chromaFitPipeline = try kernel("chroma_fit")
        chromaFitMeanPipeline = try kernel("chroma_fit_mean")
        chromaResidualPipeline = try kernel("chroma_residual")
        scalePipeline = try pipeline("scale_fragment", metalLayer.pixelFormat)
        compose2xPipeline = try pipeline("compose2x_fragment", metalLayer.pixelFormat)
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

    /// Called with a frame's serial, its render timeline and the time it
    /// reached the screen (latency probe).
    var onPresented: ((UInt64, RenderTimeline) -> Void)?
    struct RenderTimeline {
        var renderStart: CFTimeInterval = 0
        var drawable: CFTimeInterval = 0
        var committed: CFTimeInterval = 0
        var gpuDone: CFTimeInterval = 0
        var presented: CFTimeInterval = 0
    }
    /// Serial of the newest frame handed to `display`.
    var frameSerial: UInt64 { state.withLock { $0.frameSerial } }

    /// Hands a new decoded frame to the view. Frames that arrive faster than
    /// they can be drawn replace each other (newest wins). A frame identical
    /// to the current one is not drawn: a still screen streams 60 frames a
    /// second, and each would cost a full upscale and a composite (a third
    /// of an M4 Max GPU in a 6016×2538 window). Called on one thread.
    func display(_ pixelBuffer: CVPixelBuffer) {
        if let current = state.withLock({ $0.frame }), Self.samePicture(current, pixelBuffer) {
            state.withLock { $0.unchanged += 1 }
            return
        }
        state.withLock {
            $0.frame = pixelBuffer
            $0.frameSerial &+= 1
        }
        redraw()
    }

    /// Whether two decoded NV12 frames hold the same picture: size,
    /// colorimetry and every pixel. Comparing stops at the first difference;
    /// a full comparison of 2400×1012 takes about 0.1 ms.
    static func samePicture(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool {
        if a === b { return true }
        let format = CVPixelBufferGetPixelFormatType(a)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferGetPixelFormatType(b) == format,
              CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b),
              CVPixelBufferGetPlaneCount(a) == 2, CVPixelBufferGetPlaneCount(b) == 2 else { return false }
        for key in [kCVImageBufferYCbCrMatrixKey, kCVImageBufferChromaLocationTopFieldKey] {
            guard CVBufferCopyAttachment(a, key, nil) as? String == CVBufferCopyAttachment(b, key, nil) as? String else { return false }
        }
        guard CVPixelBufferLockBaseAddress(a, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly) }
        guard CVPixelBufferLockBaseAddress(b, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        for plane in 0..<2 {
            guard let pa = CVPixelBufferGetBaseAddressOfPlane(a, plane),
                  let pb = CVPixelBufferGetBaseAddressOfPlane(b, plane) else { return false }
            // Luma has one byte a pixel, interleaved chroma two a pair.
            let rowBytes = CVPixelBufferGetWidthOfPlane(a, plane) * (plane + 1)
            let strideA = CVPixelBufferGetBytesPerRowOfPlane(a, plane), strideB = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
            // Row by row: the padding between rows is not part of the picture.
            for row in 0..<CVPixelBufferGetHeightOfPlane(a, plane) where memcmp(pa + row * strideA, pb + row * strideB, rowBytes) != 0 {
                return false
            }
        }
        return true
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
        var timeline = RenderTimeline(renderStart: CACurrentMediaTime())
        let size = state.withLock { $0.drawableSize }
        if size.width > 0, size.height > 0, metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
        // The drawable first, then the frame: one that arrives while
        // nextDrawable() waits is drawn now rather than a refresh later.
        let drawable = size.width > 0 && size.height > 0 ? metalLayer.nextDrawable() : nil
        let s = state.withLock { s -> State in
            s.renderPending = false
            return s
        }
        guard let drawable, s.drawableSize == size, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        timeline.drawable = CACurrentMediaTime()
        let layout = encode(s, into: drawable.texture, commandBuffer: commandBuffer)
        let upscaled = state.withLock { $0.textUpscaling }
        commandBuffer.addCompletedHandler { [weak self] cb in self?.recordGPUTime(cb.gpuEndTime - cb.gpuStartTime, upscaled: upscaled) }
        let probe = onPresented != nil && s.frame != nil ? Locked(timeline) : nil
        if let probe, let onPresented {
            let serial = s.frameSerial
            commandBuffer.addCompletedHandler { _ in probe.withLock { $0.gpuDone = CACurrentMediaTime() } }
            drawable.addPresentedHandler { d in
                onPresented(serial, probe.withLock { t -> RenderTimeline in
                    t.presented = d.presentedTime
                    return t
                })
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        probe?.withLock { $0.committed = CACurrentMediaTime() }
        state.withLock {
            if let layout { $0.layout = layout }
            if s.frame != nil { $0.presented += 1 }
        }
    }

    /// BLITZKVM_GPU_TIMING=1 logs the average GPU time per rendered frame.
    private static let gpuTiming = ProcessInfo.processInfo.environment["BLITZKVM_GPU_TIMING"] == "1"
    private let gpuTimes = Locked((total: 0.0, count: 0, upscaledTotal: 0.0, upscaledCount: 0, slowWindows: 0))
    /// Set when frames with the text upscaler take too long on this GPU.
    private let textUpscalerTooSlow = Locked(false)
    /// The text upscaler costs about 2 ms per frame on an M4 Max for a
    /// 3000×2000 view. A GPU that needs more than this for whole frames that
    /// ran it, over three windows of 120 frames in a row (not a moment of
    /// contention), falls back to FSR for the rest of the session.
    private static let frameBudget = 0.008

    private func recordGPUTime(_ seconds: Double, upscaled: Bool) {
        let report = gpuTimes.withLock { t -> (all: Double, upscaled: Double?, tooSlow: Bool)? in
            t.total += seconds
            t.count += 1
            if upscaled {
                t.upscaledTotal += seconds
                t.upscaledCount += 1
            }
            guard t.count == 120 else { return nil }
            let upscaledAverage = t.upscaledCount >= 60 ? t.upscaledTotal / Double(t.upscaledCount) : nil
            t.slowWindows = upscaledAverage.map { $0 > Self.frameBudget } == true ? t.slowWindows + 1 : 0
            defer { t = (0, 0, 0, 0, t.slowWindows) }
            return (t.total / Double(t.count), upscaledAverage, t.slowWindows >= 3)
        }
        guard let report else { return }
        if Self.gpuTiming { AppLog.log(String(format: "render: %.2f ms GPU per frame", report.all * 1000)) }
        if report.tooSlow, let upscaledAverage = report.upscaled, !textUpscalerTooSlow.withLock({ $0 }) {
            textUpscalerTooSlow.withLock { $0 = true }
            AppLog.log(String(format: "text upscaler off: %.1f ms GPU per frame on this GPU, using FSR", upscaledAverage * 1000))
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
                                        mode: s.mode, pointScale: s.pointScale, matchScale: s.matchScale, pan: s.pan)
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
                let exactNearest = l.nearest && (s.exactPixels || s.mode == .integer)
                let fsrFilter = [.automatic, .fsr, .fsrSharp, .easu].contains(s.filter)
                let upscale = s.filter == .automatic && Self.textUpscaling && abs(scale - 2) < 0.0001 && !exactNearest
                    && !textUpscalerTooSlow.withLock({ $0 })
                state.withLock { $0.textUpscaling = upscale }
                if upscale, let upscaler = textUpscaler,
                   let (detail, regionOrigin) = enlarge2x(upscaler, source: source, layout: l, visible: (x0, y0, x1, y1),
                                                          commandBuffer: commandBuffer) {
                    var params = ComposeParams(origin: SIMD2(Float(l.x), Float(l.y)), regionOrigin: regionOrigin)
                    draw = { encoder in
                        encoder.setRenderPipelineState(self.compose2xPipeline)
                        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                        encoder.setFragmentTexture(source, index: 0)
                        encoder.setFragmentTexture(detail, index: 1)
                        encoder.setFragmentSamplerState(self.linearClampSampler, index: 0)
                        encoder.setFragmentBytes(&params, length: MemoryLayout<ComposeParams>.stride, index: 0)
                        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    }
                } else if fsrFilter, Self.fsrUpscaling || s.filter != .automatic, scale >= 1 && !identity && !exactNearest,
                   let easu = easu(source: source, layout: l, visible: (x0, y0, x1, y1), commandBuffer: commandBuffer) {
                    if s.filter == .easu {
                        // The EASU output covers the visible rect pixel for pixel.
                        var params = ScaleParams(origin: SIMD2(Float(x0), Float(y0)), scale: SIMD2(repeating: 1), filter: 0)
                        draw = { encoder in
                            encoder.setRenderPipelineState(self.scalePipeline)
                            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                            encoder.setFragmentTexture(easu, index: 0)
                            encoder.setFragmentBytes(&params, length: MemoryLayout<ScaleParams>.stride, index: 0)
                            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                        }
                    } else {
                        let stops = s.filter == .fsrSharp ? 0 : Self.rcasStops
                        var params = FSR.rcasConstants(sharpnessStops: stops, outputOrigin: SIMD2(Int32(x0), Int32(y0)))
                        draw = { encoder in
                            encoder.setRenderPipelineState(self.rcasPipeline)
                            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                            encoder.setFragmentTexture(easu, index: 0)
                            encoder.setFragmentBytes(&params, length: MemoryLayout<FSR.RcasParams>.stride, index: 0)
                            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                        }
                    }
                } else {
                    // Exact pixels and FSR's identity case use nearest; the
                    // chosen kernel otherwise (FSR filters shrink with
                    // Catmull-Rom).
                    let filter: Int32
                    switch s.filter {
                    case _ where exactNearest || (identity && fsrFilter): filter = 0
                    case .automatic where !Self.fsrUpscaling: filter = 1
                    case .automatic, .fsr, .fsrSharp, .easu: filter = scale >= 1 ? 0 : 1
                    case .nearest: filter = 0
                    case .catmullRom: filter = 1
                    case .lanczos: filter = 2
                    case .bilinear: filter = 3
                    case .sharpBilinear: filter = 4
                    }
                    var params = ScaleParams(origin: SIMD2(Float(l.x), Float(l.y)), scale: SIMD2(repeating: Float(scale)),
                                             filter: filter)
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

    /// Runs the text upscaler over the source pixels behind the visible part
    /// of a 2× layout (plus the network's margin); returns its detail texture
    /// and the source pixel its texel (0, 0) belongs to.
    private func enlarge2x(_ upscaler: TextUpscaler, source: MTLTexture, layout l: VideoLayout,
                           visible: (Double, Double, Double, Double),
                           commandBuffer: MTLCommandBuffer) -> (MTLTexture, SIMD2<Int32>)? {
        let (x0, y0, x1, y1) = visible
        let m = TextUpscaler.margin
        let sx0 = max(Int(((x0 - l.x) / 2).rounded(.down)) - m, 0), sy0 = max(Int(((y0 - l.y) / 2).rounded(.down)) - m, 0)
        let sx1 = min(Int(((x1 - l.x) / 2).rounded(.up)) + m, source.width), sy1 = min(Int(((y1 - l.y) / 2).rounded(.up)) + m, source.height)
        guard sx1 > sx0, sy1 > sy0 else { return nil }
        let origin = SIMD2<Int32>(Int32(sx0), Int32(sy0))
        guard let detail = upscaler.encode(rgb: source, origin: origin, width: sx1 - sx0, height: sy1 - sy0,
                                           commandBuffer: commandBuffer) else { return nil }
        return (detail, origin)
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
        guard let rgb = rgbTexture, let lumaTexture = CVMetalTextureGetTexture(luma),
              let chromaTexture = CVMetalTextureGetTexture(chroma) else { return nil }
        var params = Self.colorParams(for: frame)
        var guided: (fit: MTLTexture, residual: MTLTexture)?
        if params.guided != 0 {
            guided = guideChroma(luma: lumaTexture, chroma: chromaTexture, shift: params.chromaShift, commandBuffer: commandBuffer)
            if guided == nil { params.guided = 0 }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = rgb
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var rect = SIMD4<Float>(-1, -1, 2, 2)
        encoder.setRenderPipelineState(convertPipeline)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.setFragmentTexture(guided?.fit ?? chromaTexture, index: 2)
        encoder.setFragmentTexture(guided?.residual ?? chromaTexture, index: 3)
        encoder.setFragmentBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        // Keep the CVMetalTextures (and so the pixel buffer) alive until the
        // GPU is done.
        commandBuffer.addCompletedHandler { _ in _ = luma; _ = chroma }
        return rgb
    }

    /// Regularizes the guided chroma fit where luma is flat (variance in
    /// normalized units; 1 code value squared).
    private static let chromaFitEpsilon: Float = 1.0 / (255 * 255)

    /// Encodes the half-resolution passes of the guided chroma; returns the
    /// smoothed fit and the back-projection residual.
    private func guideChroma(luma: MTLTexture, chroma: MTLTexture, shift: SIMD2<Float>,
                             commandBuffer: MTLCommandBuffer) -> (fit: MTLTexture, residual: MTLTexture)? {
        let w = chroma.width, h = chroma.height
        if chromaTextures?.sited.width != w || chromaTextures?.sited.height != h {
            func make(_ format: MTLPixelFormat) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]
                d.storageMode = .private
                return device.makeTexture(descriptor: d)
            }
            if let sited = make(.r32Float), let fit = make(.rgba32Float), let fitMean = make(.rgba32Float), let residual = make(.rg32Float) {
                chromaTextures = (sited, fit, fitMean, residual)
            } else {
                chromaTextures = nil
            }
        }
        guard let t = chromaTextures, let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        let group = TextUpscaler.threadgroup(for: [chromaSitedPipeline, chromaFitPipeline, chromaFitMeanPipeline, chromaResidualPipeline])
        func dispatch(_ pipeline: MTLComputePipelineState) {
            encoder.setComputePipelineState(pipeline)
            encoder.dispatchThreadgroups(MTLSize(width: (w + group.width - 1) / group.width, height: (h + group.height - 1) / group.height, depth: 1),
                                         threadsPerThreadgroup: group)
        }
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(t.sited, index: 1)
        dispatch(chromaSitedPipeline)
        var eps = Self.chromaFitEpsilon
        encoder.setTexture(t.sited, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(t.fit, index: 2)
        encoder.setBytes(&eps, length: MemoryLayout<Float>.size, index: 0)
        dispatch(chromaFitPipeline)
        encoder.setTexture(t.fit, index: 0)
        encoder.setTexture(t.fitMean, index: 1)
        dispatch(chromaFitMeanPipeline)
        var shift = shift
        encoder.setTexture(t.fitMean, index: 0)
        encoder.setTexture(luma, index: 1)
        encoder.setTexture(chroma, index: 2)
        encoder.setTexture(t.residual, index: 3)
        encoder.setBytes(&shift, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        dispatch(chromaResidualPipeline)
        encoder.endEncoding()
        return (t.fitMean, t.residual)
    }

    /// Renders the current frame through the same pipeline into an offscreen
    /// texture of the drawable's size and writes a PNG (used by the self-test
    /// to verify color conversion and scaling).
    func writeSnapshot(to url: URL) -> Bool {
        renderQueue.sync {
            let s = state.withLock { $0 }
            let w = Int(s.drawableSize.width), h = Int(s.drawableSize.height)
            guard w > 0, h > 0, let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
            // The layer's format (the pipelines are built for it), read back
            // as 8-bit BGRA.
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: metalLayer.pixelFormat, width: w, height: h, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return false }
            _ = encode(s, into: texture, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            var packed = [UInt32](repeating: 0, count: w * h)
            texture.getBytes(&packed, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            for (i, v) in packed.enumerated() {
                // bgr10a2Unorm: blue in bits 0-9, green 10-19, red 20-29.
                func eight(_ shift: UInt32) -> UInt8 { UInt8((((v >> shift) & 0x3FF) * 255 + 511) / 1023) }
                bytes[i * 4] = eight(0)
                bytes[i * 4 + 1] = eight(10)
                bytes[i * 4 + 2] = eight(20)
                bytes[i * 4 + 3] = 255
            }
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
        /// Luma-guided chroma (left-sited 4:2:0 as the JetKVM sends it).
        var guided: Int32
        /// Added to luma above black (normalized): undoes the JetKVM bridge's
        /// truncation.
        var lumaBias: Float
    }

    /// BLITZKVM_CHROMA=bicubic turns the luma-guided chroma off (A/B checks).
    static let guidedChroma = ProcessInfo.processInfo.environment["BLITZKVM_CHROMA"] != "bicubic"

    struct ScaleParams {
        var origin: SIMD2<Float>
        var scale: SIMD2<Float>
        var filter: Int32
    }

    struct ComposeParams {
        var origin: SIMD2<Float>
        var regionOrigin: SIMD2<Int32>
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
    /// visibly wrong). BLITZKVM_COLOR_MATRIX=709 restores the declared matrix.
    static let forceBT601 = ProcessInfo.processInfo.environment["BLITZKVM_COLOR_MATRIX"] != "709"

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
        let shift = chromaShift(location: location)
        // The fit's subsampling model is the JetKVM's left-sited one.
        let guided = guidedChroma && shift == SIMD2<Float>(0.25, 0)
        return ColorParams(matrix: m, offset: SIMD3<Float>(16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0),
                           chromaShift: shift, guided: guided ? 1 : 0, lumaBias: forceBT601 ? 0.5 / 255 : 0)
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
                                       mode: s.mode, pointScale: s.pointScale, matchScale: s.matchScale, pan: s.pan)
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
