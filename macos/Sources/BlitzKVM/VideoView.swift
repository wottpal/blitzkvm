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
/// drawable at physical (Retina) resolution. Enlarged by more than 1× and up
/// to 3× (Actual Size on Retina, a full-screen window on a large display),
/// the picture goes through the learned text upscaler (TextUpscaler.swift);
/// larger enlargements use AMD FSR 1 (EASU edge-adaptive upscaling, then
/// RCAS sharpening), which keeps 1× remote text crisp without
/// nearest-neighbor stair steps or bilinear blur. Shrinking uses a widened
/// Catmull-Rom (antialiased). "Exact Pixels" uses nearest-neighbor at
/// whole-number scales instead.
///
/// A frame that changes much of the picture (a window switch, scrolling) is
/// drawn with FSR first, at half the text upscaler's cost for a whole
/// picture, and so are the frames that follow it closely; once large
/// changes stop, the next frame or a redraw goes through the text upscaler.
///
/// Typing or a moving pointer changes a few dozen pixels of the remote
/// screen. Every pass keeps its output between frames and redraws only the
/// part a change reaches through its taps: the guided chroma and the
/// conversion at the source resolution, and the scaling into a canvas the
/// size of the visible picture, which is then copied into the drawable
/// (a drawable's contents are not kept). The result is bit-identical to
/// drawing everything (VideoViewTests); any change of size, layout, filter
/// or colorimetry draws everything.
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
        /// Where the latest frames changed (luma pixels), oldest first.
        var changes: [(serial: UInt64, rect: PixelRect)] = []
        /// `frame` changed much of the picture, or came less than
        /// `sharpenDelay` after a frame that did (when the last one came).
        var largeChange = false
        var lastLargeChange: CFTimeInterval?
        var renderPending = false
        /// Renders so far, and how often the frame `representSerial` was
        /// drawn again because the window server dropped it.
        var renders: UInt64 = 0
        var representSerial: UInt64 = 0
        var represents = 0
        var presented = 0
        var unchanged = 0
        /// The last frame went through the text upscaler.
        var textUpscaling = false

        /// Where the frames after `serial` up to `frame` changed; nil when
        /// that is unknown (nothing drawn yet, or more frames than the
        /// history keeps).
        func changes(since serial: UInt64) -> PixelRect? {
            guard serial != 0, let oldest = changes.first, oldest.serial <= serial + 1 else { return nil }
            return changes.reduce(.empty) { $1.serial > serial ? $0.union($1.rect) : $0 }
        }
    }

    /// Frames whose change is remembered. Frames that arrive while a render
    /// waits for a drawable are drawn together (newest wins), and their
    /// changes add up.
    private static let changeHistory = 16

    private let state = Locked(State())
    private let renderQueue = DispatchQueue(label: "jetkvm.render", qos: .userInteractive)
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var convertPipeline: MTLRenderPipelineState!
    private var scalePipeline: MTLRenderPipelineState!
    private var easuPipeline: MTLRenderPipelineState!
    private var rcasPipeline: MTLRenderPipelineState!
    private var quadVertex: MTLFunction!
    /// The text upscaler and its compose pass (our quad vertex, its fragment),
    /// made on first use; nil where they do not build.
    private lazy var textUpscaler: (upscaler: TextUpscaler, compose: MTLRenderPipelineState)? = {
        guard let upscaler = TextUpscaler(device: device) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = quadVertex
        d.fragmentFunction = upscaler.composeFunction
        d.colorAttachments[0].pixelFormat = metalLayer.pixelFormat
        return (try? device.makeRenderPipelineState(descriptor: d)).map { (upscaler, $0) }
    }()
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
    /// Serial of the frame rgbTexture holds (0: none), and how it was
    /// converted: redraws for a pan or resize reuse it, and the next frame
    /// converts only what changed since. (Not the buffer's identity:
    /// VideoToolbox recycles buffers.)
    private var convertedSerial: UInt64 = 0
    private var convertedParams: ColorParams?
    /// The pixels converted since the text upscaler's network last ran
    /// (nil: any): only those can differ from what it saw.
    private var upscalerStale: PixelRect?
    /// EASU output, sized to the visible part of the scaled video.
    private var easuTexture: MTLTexture?
    /// The scaled picture (the visible part of the video), kept between
    /// frames, and what it shows.
    private var canvasTexture: MTLTexture?
    private var canvasContent: (serial: UInt64, key: CanvasKey)?
    /// How the last picture was scaled: a change of it draws everything
    /// anyway, straight into the target.
    private var previousKey: CanvasKey?
    /// The share of the canvas the last render drew (GPU timing and tests;
    /// 1 for pictures drawn without it).
    private(set) var redrawnShare = 1.0
    /// The last render drew a large change with FSR instead of the text
    /// upscaler (`render` redraws it once large changes stop).
    private(set) var sharpenPending = false

    /// How the canvas was drawn: any difference redraws all of it.
    private struct CanvasKey: Equatable {
        var layout: VideoLayout
        var visible: PixelRect
        var sourceWidth: Int
        var sourceHeight: Int
        var resample: Resample
    }

    private enum Resample: Equatable {
        /// EASU, then RCAS with this strength (stops).
        case fsr(Float)
        /// EASU alone: its output is the canvas.
        case easu
        /// The text upscaler's network, then its compose pass.
        case textUpscaler
        /// scale_fragment's filter.
        case filter(Int32)
    }
    /// RCAS strength in stops (0 = strongest). 0.5 sharpens text edges
    /// without a dark rim around light text on dark backgrounds.
    /// BLITZKVM_RCAS_STOPS overrides it (A/B checks).
    private static let rcasStops = Float(ProcessInfo.processInfo.environment["BLITZKVM_RCAS_STOPS"] ?? "") ?? 0.5
    /// BLITZKVM_UPSCALER=fsr uses FSR instead of the text upscaler,
    /// =catmull enlarges with Catmull-Rom instead of either (A/B checks).
    private static let fsrUpscaling = ProcessInfo.processInfo.environment["BLITZKVM_UPSCALER"] != "catmull"
    private static let textUpscaling = fsrUpscaling && ProcessInfo.processInfo.environment["BLITZKVM_UPSCALER"] != "fsr"
    /// A frame whose luma changed visibly in more than this share of the
    /// picture's 64×64-pixel blocks (`changedShare`), and the frames less
    /// than `sharpenDelay` after it, are drawn with FSR, and the text
    /// upscaler redraws the picture once no large change came for that long.
    /// Through the network, a whole new picture costs an M4 Max 11 ms of GPU
    /// at 6016×2538, FSR 5, and scrolling 7.8 ms a frame, close to the
    /// slow-GPU fallback's budget; a change of a seventh of the picture added
    /// 3 ms to decode-to-screen. So anything above a tenth comes sooner
    /// through FSR; typing and the pointer go through the upscaler directly.
    private static let largeChangeShare = 0.1
    private static let sharpenDelay: CFTimeInterval = 0.1
    /// How often a frame whose drawable was dropped is drawn again.
    private static let maxRepresents = 3

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

    // The chroma kernels run over the sites from `origin` on: the part of
    // the frame that changed, or all of it.
    kernel void chroma_sited_luma(texture2d<float, access::read> luma [[texture(0)]],
                                  texture2d<float, access::write> out [[texture(1)]],
                                  constant uint2 &origin [[buffer(1)]],
                                  uint2 tid [[thread_position_in_grid]]) {
        uint2 gid = tid + origin;
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        out.write(float4(sitedLuma(luma, int2(gid))), gid);
    }

    // Per chroma site: a (cb, cr) and b (cb, cr) of the local linear fit.
    kernel void chroma_fit(texture2d<float, access::read> sited [[texture(0)]],
                           texture2d<float, access::read> chroma [[texture(1)]],
                           texture2d<float, access::write> out [[texture(2)]],
                           constant float &eps [[buffer(0)]],
                           constant uint2 &origin [[buffer(1)]],
                           uint2 tid [[thread_position_in_grid]]) {
        uint2 gid = tid + origin;
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
                                constant uint2 &origin [[buffer(1)]],
                                uint2 tid [[thread_position_in_grid]]) {
        uint2 gid = tid + origin;
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
                                constant uint2 &origin [[buffer(1)]],
                                uint2 tid [[thread_position_in_grid]]) {
        uint2 gid = tid + origin;
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
        quadVertex = library.makeFunction(name: "quad_vertex")
        func pipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = quadVertex
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
    /// of an M4 Max GPU in a 6016×2538 window), and a changed one redraws
    /// only where it changed. Called on one thread, `time` being when the
    /// frame arrived. Returns where the frame differs from the one before
    /// (in its pixels) and which part of that is visible: the device's
    /// encoder keeps re-coding a still picture by a few code values (about
    /// 2,500 pixels a frame on a desktop), which is no change to act on.
    @discardableResult
    func display(_ pixelBuffer: CVPixelBuffer, at time: CFTimeInterval = CACurrentMediaTime()) -> Shown {
        let current = state.withLock { $0.frame }
        let changed = current.map { Self.changedRect($0, pixelBuffer) }
            ?? PixelRect(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        if changed.isEmpty {
            state.withLock { $0.unchanged += 1 }
            return Shown(changed: changed, visible: [])
        }
        let visible = current.map { Self.visibleChange($0, pixelBuffer, in: changed) } ?? (share: 1, rects: [changed])
        let large = visible.share > Self.largeChangeShare
        state.withLock {
            $0.frame = pixelBuffer
            $0.frameSerial &+= 1
            $0.changes.append(($0.frameSerial, changed))
            if $0.changes.count > Self.changeHistory { $0.changes.removeFirst() }
            if large { $0.lastLargeChange = time }
            $0.largeChange = $0.lastLargeChange.map { time - $0 < Self.sharpenDelay } == true
        }
        redraw()
        return Shown(changed: changed, visible: visible.rects)
    }

    /// What `display` found: the changed pixels, and the 64×64 blocks among
    /// them that changed visibly (more than `visibleDelta`).
    struct Shown {
        var changed: PixelRect
        var visible: [PixelRect]
    }

    /// Where two decoded NV12 frames differ, in luma pixels of `b`: empty
    /// for the same picture, all of `b` when they cannot be compared (size,
    /// format, colorimetry). Whole rows are compared down to the first and
    /// up to the last that differ; between those, only the bytes left and
    /// right of the columns found so far. That stays within about one pass
    /// over the frame: about 0.1 ms for 2400×1012, 0.2 ms at most.
    static func changedRect(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> PixelRect {
        let all = PixelRect(width: CVPixelBufferGetWidth(b), height: CVPixelBufferGetHeight(b))
        if a === b { return .empty }
        guard comparable(a, b), CVPixelBufferLockBaseAddress(a, .readOnly) == kCVReturnSuccess else { return all }
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly) }
        guard CVPixelBufferLockBaseAddress(b, .readOnly) == kCVReturnSuccess else { return all }
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        var changed = PixelRect.empty
        for plane in 0..<2 {
            guard let pa = CVPixelBufferGetBaseAddressOfPlane(a, plane),
                  let pb = CVPixelBufferGetBaseAddressOfPlane(b, plane) else { return all }
            // Luma has one byte a pixel, interleaved chroma two a pair.
            let rowBytes = CVPixelBufferGetWidthOfPlane(a, plane) * (plane + 1)
            let strideA = CVPixelBufferGetBytesPerRowOfPlane(a, plane), strideB = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
            // Row by row: the padding between rows is not part of the picture.
            let differs = { (row: Int) in memcmp(pa + row * strideA, pb + row * strideB, rowBytes) != 0 }
            let height = CVPixelBufferGetHeightOfPlane(a, plane)
            guard let top = (0..<height).first(where: differs), let bottom = (top..<height).last(where: differs) else { continue }
            var lo = rowBytes, hi = 0
            for row in top...bottom {
                let ra = UnsafeRawPointer(pa + row * strideA), rb = UnsafeRawPointer(pb + row * strideB)
                lo = firstDifference(ra, rb, 0..<lo) ?? lo
                hi = lastDifference(ra, rb, hi..<rowBytes).map { $0 + 1 } ?? hi
                if lo == 0 && hi == rowBytes { break }
            }
            // A chroma pair covers 2×2 luma pixels.
            changed = changed.union(plane == 0 ? PixelRect(x0: lo, y0: top, x1: hi, y1: bottom + 1)
                                               : PixelRect(x0: lo / 2 * 2, y0: top * 2, x1: (hi + 1) / 2 * 2, y1: (bottom + 1) * 2))
        }
        return changed.intersection(all)
    }

    /// The share of `b`'s 64×64-pixel blocks in which some pixel's luma
    /// changed visibly since `a` (by more than `visibleDelta`), looking only
    /// inside `rect` (where `changedRect` found the change); 1 for frames
    /// that cannot be compared. A block stops at its first visible change,
    /// so a whole-frame change costs about one row per block.
    static func changedShare(_ a: CVPixelBuffer, _ b: CVPixelBuffer, in rect: PixelRect) -> Double {
        visibleChange(a, b, in: rect).share
    }

    /// The share as above, and the blocks that changed visibly (runs of
    /// neighbours in a row joined), each grown by `visibleMargin` within
    /// the change: a glyph's coding artifacts spill a few rows into the
    /// next block, invisibly.
    static func visibleChange(_ a: CVPixelBuffer, _ b: CVPixelBuffer, in rect: PixelRect) -> (share: Double, rects: [PixelRect]) {
        let size = 64
        let all = PixelRect(width: CVPixelBufferGetWidth(b), height: CVPixelBufferGetHeight(b))
        guard comparable(a, b), CVPixelBufferLockBaseAddress(a, .readOnly) == kCVReturnSuccess else { return (1, [all]) }
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly) }
        guard CVPixelBufferLockBaseAddress(b, .readOnly) == kCVReturnSuccess else { return (1, [all]) }
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0), let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0) else { return (1, [all]) }
        let strideA = CVPixelBufferGetBytesPerRowOfPlane(a, 0), strideB = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        let area = rect.intersection(all), cells = area.cells(of: size)
        var changed = 0, rects: [PixelRect] = []
        for y in cells.y0..<cells.y1 {
            var run = PixelRect.empty
            for x in cells.x0..<cells.x1 {
                let block = PixelRect(x0: x * size, y0: y * size, x1: (x + 1) * size, y1: (y + 1) * size).intersection(area)
                let visible = (block.y0..<block.y1).contains {
                    changesVisibly(pa + $0 * strideA + block.x0, pb + $0 * strideB + block.x0, count: block.width)
                }
                if visible {
                    changed += 1
                    run = run.union(block)
                } else if !run.isEmpty {
                    rects.append(run.outset(by: visibleMargin).intersection(area))
                    run = .empty
                }
            }
            if !run.isEmpty { rects.append(run.outset(by: visibleMargin).intersection(area)) }
        }
        let blocks = all.cells(of: size)
        return (Double(changed) / Double(blocks.width * blocks.height), rects)
    }

    /// The still refresh re-encodes the same picture: in JetKVM recordings,
    /// 90% of the blocks it changes change by 2–21 code values, against 220
    /// for scrolling or a window switch, which move edges.
    static let visibleDelta: UInt8 = 32
    static let visibleMargin = 8

    /// Whether some byte of two rows differs by more than `visibleDelta`.
    private static func changesVisibly(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, count: Int) -> Bool {
        let limit = SIMD16<UInt8>(repeating: visibleDelta)
        var i = 0
        while i + 16 <= count {
            let x = a.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self), y = b.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
            if any(pointwiseMax(x, y) &- pointwiseMin(x, y) .> limit) { return true }
            i += 16
        }
        return (i..<count).contains {
            abs(Int(a.load(fromByteOffset: $0, as: UInt8.self)) - Int(b.load(fromByteOffset: $0, as: UInt8.self))) > Int(visibleDelta)
        }
    }

    /// Whether two decoded frames can be compared byte for byte: NV12 of the
    /// same size and colorimetry.
    private static func comparable(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(a)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferGetPixelFormatType(b) == format,
              CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b),
              CVPixelBufferGetPlaneCount(a) == 2, CVPixelBufferGetPlaneCount(b) == 2 else { return false }
        return [kCVImageBufferYCbCrMatrixKey, kCVImageBufferChromaLocationTopFieldKey].allSatisfy {
            CVBufferCopyAttachment(a, $0, nil) as? String == CVBufferCopyAttachment(b, $0, nil) as? String
        }
    }

    /// The first byte offset in `range` where the two rows differ.
    private static func firstDifference(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, _ range: Range<Int>) -> Int? {
        var i = range.lowerBound
        while i + 8 <= range.upperBound {
            let x = a.loadUnaligned(fromByteOffset: i, as: UInt64.self) ^ b.loadUnaligned(fromByteOffset: i, as: UInt64.self)
            if x != 0 { return i + x.trailingZeroBitCount / 8 }
            i += 8
        }
        return (i..<range.upperBound).first { a.load(fromByteOffset: $0, as: UInt8.self) != b.load(fromByteOffset: $0, as: UInt8.self) }
    }

    /// The last byte offset in `range` where the two rows differ.
    private static func lastDifference(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, _ range: Range<Int>) -> Int? {
        var end = range.upperBound
        while end - 8 >= range.lowerBound {
            let x = a.loadUnaligned(fromByteOffset: end - 8, as: UInt64.self) ^ b.loadUnaligned(fromByteOffset: end - 8, as: UInt64.self)
            if x != 0 { return end - 1 - x.leadingZeroBitCount / 8 }
            end -= 8
        }
        return (range.lowerBound..<end).last { a.load(fromByteOffset: $0, as: UInt8.self) != b.load(fromByteOffset: $0, as: UInt8.self) }
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
            s.renders &+= 1
            return s
        }
        guard let drawable, s.drawableSize == size, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        // After a pause, the window server sometimes drops the first drawable
        // presented (presentedTime 0) and keeps showing the one before; with
        // no newer frame, the change stayed off screen until the next one
        // (a pointer move on a still screen: about 340 ms, in a third of
        // the moves). It is drawn again then, a few times at most (a window
        // that is not on screen has every drawable dropped).
        let renderID = s.renders, renderSerial = s.frameSerial
        drawable.addPresentedHandler { [weak self] d in
            guard d.presentedTime == 0, let self else { return }
            let again = self.state.withLock { s -> Bool in
                guard s.renders == renderID, s.frame != nil else { return false }
                if s.representSerial != renderSerial { (s.representSerial, s.represents) = (renderSerial, 0) }
                guard s.represents < Self.maxRepresents else { return false }
                s.represents += 1
                return true
            }
            if again { self.redraw() }
        }
        timeline.drawable = CACurrentMediaTime()
        let layout = encode(s, into: drawable.texture, commandBuffer: commandBuffer)
        let upscaled = state.withLock { $0.textUpscaling }
        let redrawn = redrawnShare
        commandBuffer.addCompletedHandler { [weak self] cb in
            self?.recordGPUTime(cb.gpuEndTime - cb.gpuStartTime, upscaled: upscaled, redrawn: redrawn)
        }
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
        // A large change that stays on screen is drawn again, sharp: no later
        // frame may come (a still screen repeats the same picture).
        if sharpenPending {
            renderQueue.asyncAfter(deadline: .now() + Self.sharpenDelay) { [weak self, serial = s.frameSerial] in
                guard let self, self.state.withLock({ $0.frameSerial == serial }) else { return }
                self.redraw()
            }
        }
    }

    /// BLITZKVM_GPU_TIMING=1 logs the average GPU time per rendered frame,
    /// and how much of the picture was drawn again.
    private static let gpuTiming = ProcessInfo.processInfo.environment["BLITZKVM_GPU_TIMING"] == "1"
    private let gpuTimes = Locked((total: 0.0, count: 0, redrawn: 0.0, upscaledTotal: 0.0, upscaledCount: 0, slowWindows: 0))
    /// Set when frames with the text upscaler take too long on this GPU.
    private let textUpscalerTooSlow = Locked(false)
    /// Frames through the text upscaler cost an M4 Max 0.8 ms GPU for typing
    /// and 11 ms when everything changed (6016×2538 from 2400×1012). A GPU
    /// that needs more than this for whole frames that ran it, over three
    /// windows of 120 frames in a row (not a moment of contention), falls
    /// back to FSR for the rest of the session.
    private static let frameBudget = 0.008

    private func recordGPUTime(_ seconds: Double, upscaled: Bool, redrawn: Double) {
        let report = gpuTimes.withLock { t -> (all: Double, redrawn: Double, upscaled: Double?, tooSlow: Bool)? in
            t.total += seconds
            t.count += 1
            t.redrawn += redrawn
            if upscaled {
                t.upscaledTotal += seconds
                t.upscaledCount += 1
            }
            guard t.count == 120 else { return nil }
            let upscaledAverage = t.upscaledCount >= 60 ? t.upscaledTotal / Double(t.upscaledCount) : nil
            t.slowWindows = upscaledAverage.map { $0 > Self.frameBudget } == true ? t.slowWindows + 1 : 0
            defer { t = (0, 0, 0, 0, 0, t.slowWindows) }
            return (t.total / Double(t.count), t.redrawn / Double(t.count), upscaledAverage, t.slowWindows >= 3)
        }
        guard let report else { return }
        if Self.gpuTiming {
            AppLog.log(String(format: "render: %.2f ms GPU per frame, %.1f%% of the picture drawn", report.all * 1000, report.redrawn * 100))
        }
        if report.tooSlow, let upscaledAverage = report.upscaled, !textUpscalerTooSlow.withLock({ $0 }) {
            textUpscalerTooSlow.withLock { $0 = true }
            AppLog.log(String(format: "text upscaler off: %.1f ms GPU per frame on this GPU, using FSR", upscaledAverage * 1000))
        }
    }

    /// Encodes the frame into `target`; returns the layout used (nil without
    /// a frame).
    private func encode(_ s: State, into target: MTLTexture, commandBuffer: MTLCommandBuffer) -> VideoLayout? {
        let size = CGSize(width: target.width, height: target.height)
        // The canvas can build on the frame converted before this one.
        let previousSerial = convertedSerial
        // A large change is drawn with FSR once; a redraw of the same frame
        // sharpens it.
        let largeChange = s.largeChange && s.frameSerial != convertedSerial
        var source: MTLTexture?
        var converted = PixelRect.empty
        if let frame = s.frame {
            if s.frameSerial == convertedSerial, let rgb = rgbTexture {
                source = rgb
            } else if let (luma, chroma) = textures(for: frame),
                      let region = convert(s, luma: luma, chroma: chroma, commandBuffer: commandBuffer) {
                source = rgbTexture
                converted = region
                upscalerStale = upscalerStale?.union(region)
            }
        }
        redrawnShare = 1
        sharpenPending = false
        var layout: VideoLayout?
        // The final pass: the visible rect, drawn by `draw`.
        var rect = SIMD4<Float>()
        var draw: Draw?
        if let source {
            let l = VideoLayout.compute(videoWidth: source.width, videoHeight: source.height,
                                        drawableWidth: size.width, drawableHeight: size.height,
                                        mode: s.mode, pointScale: s.pointScale, matchScale: s.matchScale, pan: s.pan)
            layout = l
            // Only the visible part of the video rect (it overflows when
            // panning).
            let visible = l.visibleRect(drawableWidth: size.width, drawableHeight: size.height)
            if !visible.isEmpty {
                rect = Self.ndc(visible, width: target.width, height: target.height)
                let scale = l.width / Double(source.width)
                let identity = abs(scale - 1) < 0.0001
                // Whole-multiple mode exists for exact pixels; elsewhere it is a preference.
                let exactNearest = l.nearest && (s.exactPixels || s.mode == .integer)
                let fsrFilter = [.automatic, .fsr, .fsrSharp, .easu].contains(s.filter)
                let upscale = s.filter == .automatic && Self.textUpscaling && !identity && scale > 1 && scale <= TextUpscaler.maxScale
                    && !exactNearest && !textUpscalerTooSlow.withLock({ $0 }) && textUpscaler != nil
                sharpenPending = upscale && largeChange
                state.withLock { $0.textUpscaling = upscale && !largeChange }
                let resample: Resample
                if upscale {
                    resample = largeChange ? .fsr(Self.rcasStops) : .textUpscaler
                } else if fsrFilter, Self.fsrUpscaling || s.filter != .automatic, scale >= 1 && !identity && !exactNearest {
                    resample = s.filter == .easu ? .easu : .fsr(s.filter == .fsrSharp ? 0 : Self.rcasStops)
                } else {
                    // Exact pixels and FSR's identity case use nearest; the
                    // chosen kernel otherwise (FSR filters shrink with
                    // Catmull-Rom).
                    switch s.filter {
                    case _ where exactNearest || (identity && fsrFilter): resample = .filter(0)
                    case .automatic where !Self.fsrUpscaling: resample = .filter(1)
                    case .automatic, .fsr, .fsrSharp, .easu: resample = .filter(scale >= 1 ? 0 : 1)
                    case .nearest: resample = .filter(0)
                    case .catmullRom: resample = .filter(1)
                    case .lanczos: resample = .filter(2)
                    case .bilinear: resample = .filter(3)
                    case .sharpBilinear: resample = .filter(4)
                    }
                }
                let key = CanvasKey(layout: l, visible: visible, sourceWidth: source.width, sourceHeight: source.height, resample: resample)
                draw = self.scale(source: source, key: key, changed: converted, since: previousSerial, commandBuffer: commandBuffer)
            }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        if let draw {
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            draw(encoder)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        return layout
    }

    /// Sets a pass's pipeline and fragment inputs; the pass draws one quad.
    private typealias Draw = (MTLRenderCommandEncoder) -> Void

    /// Runs the text upscaler over the source pixels behind the visible part
    /// of the layout (plus the network's margin); returns its detail texture
    /// and the source pixel its first sub-pixel block belongs to.
    private func enlarge(_ upscaler: TextUpscaler, source: MTLTexture, key: CanvasKey,
                         commandBuffer: MTLCommandBuffer) -> (MTLTexture, SIMD2<Int32>)? {
        let l = key.layout, v = key.visible, m = TextUpscaler.margin
        let sx = l.width / Double(source.width), sy = l.height / Double(source.height)
        let sx0 = max(Int(((Double(v.x0) - l.x) / sx).rounded(.down)) - m, 0), sy0 = max(Int(((Double(v.y0) - l.y) / sy).rounded(.down)) - m, 0)
        let sx1 = min(Int(((Double(v.x1) - l.x) / sx).rounded(.up)) + m, source.width)
        let sy1 = min(Int(((Double(v.y1) - l.y) / sy).rounded(.up)) + m, source.height)
        guard sx1 > sx0, sy1 > sy0 else { return nil }
        let origin = SIMD2<Int32>(Int32(sx0), Int32(sy0))
        guard let detail = upscaler.encode(rgb: source, origin: origin, width: sx1 - sx0, height: sy1 - sy0, dirty: upscalerStale,
                                           commandBuffer: commandBuffer) else { return nil }
        upscalerStale = .empty
        return (detail, origin)
    }

    /// Encodes the scaling of the converted frame; returns how to draw the
    /// visible part of the video into the target. A small change redraws
    /// only the canvas pixels whose filter taps reach the `changed` source
    /// pixels, then the canvas (the visible part, kept between frames) is
    /// copied. While everything changes (scrolling, video, a resize or pan),
    /// the picture goes straight into the target: keeping the canvas would
    /// add a copy of all of it (0.45 ms at 6016×2538). The next small change
    /// draws the canvas whole again. EASU alone keeps its own output.
    private func scale(source: MTLTexture, key: CanvasKey, changed: PixelRect, since serial: UInt64,
                       commandBuffer: MTLCommandBuffer) -> Draw? {
        let w = key.visible.width, h = key.visible.height, all = PixelRect(width: w, height: h)
        let l = key.layout
        let scale = l.width / Double(key.sourceWidth)
        // The widest taps (Lanczos-3, EASU's 4×4) reach 3 source pixels,
        // widened by 1/scale when shrinking (at most 12), the text upscaler
        // its margin (the network's receptive field, then the footprint),
        // plus one to spare; then two canvas pixels for RCAS's neighbors and
        // rounding.
        let reach = (key.resample == .textUpscaler ? Double(TextUpscaler.margin) : min(3 / min(scale, 1), 12)) + 1
        let reached = l.destinationRect(of: changed, videoWidth: key.sourceWidth, videoHeight: key.sourceHeight, reach: reach)
            .offsetBy(dx: -key.visible.x0, dy: -key.visible.y0).outset(by: 2).intersection(all)
        let direct = key.resample != .easu && (reached == all || key != previousKey)
        let valid = canvasContent.map { $0.key == key && $0.serial == serial } ?? false
        let region = direct || !valid ? all : reached
        previousKey = key
        canvasContent = nil
        redrawnShare = Double(region.width * region.height) / Double(w * h)
        // The target pixel that canvas pixel (0, 0) stands for, and where the
        // video's top-left corner lies in the pass's target.
        let corner = direct ? (x: key.visible.x0, y: key.visible.y0) : (x: 0, y: 0)
        let origin = SIMD2(Float(l.x - Double(key.visible.x0 - corner.x)), Float(l.y - Double(key.visible.y0 - corner.y)))
        let draw: Draw
        switch key.resample {
        case .fsr(let stops):
            guard let easu = renderTarget(&easuTexture, width: w, height: h, format: .rgba16Float),
                  easuPass(source: source, key: key, into: easu, region: region.outset(by: 1).intersection(all),
                           commandBuffer: commandBuffer) else { return nil }
            var params = FSR.rcasConstants(sharpnessStops: stops, outputOrigin: SIMD2(Int32(corner.x), Int32(corner.y)))
            draw = { encoder in
                encoder.setRenderPipelineState(self.rcasPipeline)
                encoder.setFragmentTexture(easu, index: 0)
                encoder.setFragmentBytes(&params, length: MemoryLayout<FSR.RcasParams>.stride, index: 0)
            }
        case .easu:
            guard let easu = renderTarget(&easuTexture, width: w, height: h, format: .rgba16Float),
                  easuPass(source: source, key: key, into: easu, region: region, commandBuffer: commandBuffer) else { return nil }
            canvasContent = (convertedSerial, key)
            return copy(easu, to: key.visible)
        case .textUpscaler:
            guard let (upscaler, compose) = textUpscaler,
                  let (detail, regionOrigin) = enlarge(upscaler, source: source, key: key, commandBuffer: commandBuffer) else { return nil }
            var params = TextUpscaler.ComposeParams(origin: origin, regionOrigin: regionOrigin,
                                                    frame: SIMD2(Int32(source.width), Int32(source.height)),
                                                    scale: SIMD2(l.width / Double(source.width), l.height / Double(source.height)), n: upscaler.n)
            draw = { encoder in
                encoder.setRenderPipelineState(compose)
                encoder.setFragmentTexture(source, index: 0)
                encoder.setFragmentTexture(detail, index: 1)
                encoder.setFragmentSamplerState(self.linearClampSampler, index: 0)
                encoder.setFragmentBytes(&params, length: MemoryLayout<TextUpscaler.ComposeParams>.stride, index: 0)
            }
        case .filter(let filter):
            var params = ScaleParams(origin: origin, scale: SIMD2(repeating: Float(scale)), filter: filter)
            draw = { encoder in
                encoder.setRenderPipelineState(self.scalePipeline)
                encoder.setFragmentTexture(source, index: 0)
                encoder.setFragmentBytes(&params, length: MemoryLayout<ScaleParams>.stride, index: 0)
            }
        }
        if direct { return draw }
        guard let canvas = renderTarget(&canvasTexture, width: w, height: h, format: metalLayer.pixelFormat),
              drawPass(into: canvas, region: region, commandBuffer: commandBuffer, draw: draw) else { return nil }
        canvasContent = (convertedSerial, key)
        return copy(canvas, to: key.visible)
    }

    /// Draws `texture` pixel for pixel into `rect` of the target.
    private func copy(_ texture: MTLTexture, to rect: PixelRect) -> Draw {
        var params = ScaleParams(origin: SIMD2(Float(rect.x0), Float(rect.y0)), scale: SIMD2(repeating: 1), filter: 0)
        return { encoder in
            encoder.setRenderPipelineState(self.scalePipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&params, length: MemoryLayout<ScaleParams>.stride, index: 0)
        }
    }

    /// FSR EASU over `region` of `out`, which holds the visible part of the
    /// scaled video (RCAS then sharpens it).
    private func easuPass(source: MTLTexture, key: CanvasKey, into out: MTLTexture, region: PixelRect,
                          commandBuffer: MTLCommandBuffer) -> Bool {
        let l = key.layout
        // The scaled image starts at (l.x - visible.x0, l.y - visible.y0) inside `out`.
        var params = FSR.easuConstants(inputSize: SIMD2(Float(source.width), Float(source.height)),
                                       outputSize: SIMD2(Float(l.width), Float(l.height)),
                                       outputOffset: SIMD2(Float(l.x - Double(key.visible.x0)), Float(l.y - Double(key.visible.y0))))
        return drawPass(into: out, region: region, commandBuffer: commandBuffer) { encoder in
            encoder.setRenderPipelineState(self.easuPipeline)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentSamplerState(self.linearClampSampler, index: 0)
            encoder.setFragmentBytes(&params, length: MemoryLayout<FSR.EasuParams>.stride, index: 0)
        }
    }

    /// Draws over `region` of `target` (nothing for an empty region); the
    /// rest of `target` keeps its contents. Tiles the quad misses cost
    /// nothing: a 200×200 quad into 6016×2538 measured 0.04 ms with .load,
    /// the whole target 0.42 ms.
    private func drawPass(into target: MTLTexture, region: PixelRect, commandBuffer: MTLCommandBuffer, draw: Draw) -> Bool {
        guard !region.isEmpty else { return true }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = region == PixelRect(width: target.width, height: target.height) ? .dontCare : .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var rect = Self.ndc(region, width: target.width, height: target.height)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        draw(encoder)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    /// `rect` in the normalized device coordinates of a `width`×`height`
    /// target (origin bottom-left), as the quad vertex shaders take it.
    private static func ndc(_ rect: PixelRect, width: Int, height: Int) -> SIMD4<Float> {
        let w = Double(width), h = Double(height)
        return SIMD4(Float(Double(rect.x0) / w * 2 - 1), Float(1 - Double(rect.y1) / h * 2),
                     Float(Double(rect.width) / w * 2), Float(Double(rect.height) / h * 2))
    }

    /// `texture`, or a new private render target when it has another size
    /// or format.
    private func renderTarget(_ texture: inout MTLTexture?, width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
        if texture?.width != width || texture?.height != height || texture?.pixelFormat != format {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            texture = device.makeTexture(descriptor: d)
        }
        return texture
    }

    /// How far a change reaches, each with one to spare. Through the guided
    /// chroma passes, in chroma sites beyond the changed pixels' own: sited
    /// luma one (to the right), fit, fit mean and residual one each. Into
    /// the converted picture, in luma pixels: an odd column's Catmull-Rom
    /// taps reach two sites left and one right of its own, so a changed
    /// residual site reaches 2 × (4 + 1) + 1 = 11 pixels (unguided chroma: 5).
    private static let chromaReach = 5
    private static let convertReach = 12

    /// Pass 1 into the (reused) RGB texture at the frame's size: all of it,
    /// or only the pixels that the frames since the last conversion changed,
    /// and those their chroma reaches. Returns the pixels it drew (nil if it
    /// could not convert).
    private func convert(_ s: State, luma: CVMetalTexture, chroma: CVMetalTexture, commandBuffer: MTLCommandBuffer) -> PixelRect? {
        guard let frame = s.frame else { return nil }
        let all = PixelRect(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        var params = Self.colorParams(for: frame)
        let changed = rgbTexture?.width == all.width && rgbTexture?.height == all.height && params == convertedParams
            ? s.changes(since: convertedSerial) : nil
        convertedSerial = 0
        guard let rgb = renderTarget(&rgbTexture, width: all.width, height: all.height, format: .rgba16Float),
              let lumaTexture = CVMetalTextureGetTexture(luma),
              let chromaTexture = CVMetalTextureGetTexture(chroma) else { return nil }
        var region = changed.map { $0.outset(by: Self.convertReach).intersection(all) } ?? all
        var guided: (fit: MTLTexture, residual: MTLTexture)?
        if params.guided != 0 {
            let sites = PixelRect(width: chromaTexture.width, height: chromaTexture.height)
            guided = guideChroma(luma: lumaTexture, chroma: chromaTexture, shift: params.chromaShift,
                                 sites: changed.map { $0.cells(of: 2).outset(by: Self.chromaReach).intersection(sites) } ?? sites,
                                 commandBuffer: commandBuffer)
            if guided == nil {
                params.guided = 0
                region = all
            }
        }
        guard drawPass(into: rgb, region: region, commandBuffer: commandBuffer, draw: { encoder in
            encoder.setRenderPipelineState(self.convertPipeline)
            encoder.setFragmentTexture(lumaTexture, index: 0)
            encoder.setFragmentTexture(chromaTexture, index: 1)
            encoder.setFragmentTexture(guided?.fit ?? chromaTexture, index: 2)
            encoder.setFragmentTexture(guided?.residual ?? chromaTexture, index: 3)
            encoder.setFragmentBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)
        }) else { return nil }
        // Keep the CVMetalTextures (and so the pixel buffer) alive until the
        // GPU is done.
        commandBuffer.addCompletedHandler { _ in _ = luma; _ = chroma }
        convertedSerial = s.frameSerial
        convertedParams = params
        return region
    }

    /// Regularizes the guided chroma fit where luma is flat (variance in
    /// normalized units; 1 code value squared).
    private static let chromaFitEpsilon: Float = 1.0 / (255 * 255)

    /// Encodes the half-resolution passes of the guided chroma over `sites`
    /// (the textures keep the other sites from earlier frames); returns the
    /// smoothed fit and the back-projection residual.
    private func guideChroma(luma: MTLTexture, chroma: MTLTexture, shift: SIMD2<Float>, sites: PixelRect,
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
        guard let t = chromaTextures else { return nil }
        guard !sites.isEmpty else { return (t.fitMean, t.residual) }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        let group = TextUpscaler.threadgroup(for: [chromaSitedPipeline, chromaFitPipeline, chromaFitMeanPipeline, chromaResidualPipeline])
        var origin = SIMD2<UInt32>(UInt32(sites.x0), UInt32(sites.y0))
        encoder.setBytes(&origin, length: MemoryLayout<SIMD2<UInt32>>.size, index: 1)
        func dispatch(_ pipeline: MTLComputePipelineState) {
            encoder.setComputePipelineState(pipeline)
            encoder.dispatchThreadgroups(MTLSize(width: (sites.width + group.width - 1) / group.width,
                                                 height: (sites.height + group.height - 1) / group.height, depth: 1),
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
        let size = state.withLock { $0.drawableSize }
        let w = Int(size.width), h = Int(size.height)
        guard let packed = renderOffscreen(width: w, height: h) else { return false }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for (i, v) in packed.enumerated() {
            // bgr10a2Unorm: blue in bits 0-9, green 10-19, red 20-29.
            func eight(_ shift: UInt32) -> UInt8 {
                let ten: UInt32 = (v >> shift) & 0x3FF
                return UInt8((ten * 255 + 511) / 1023)
            }
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

    /// Renders the current frame into an offscreen `width`×`height` target in
    /// the layer's format (the pipelines are built for it); returns its
    /// bgr10a2 pixels, row by row.
    func renderOffscreen(width w: Int, height h: Int) -> [UInt32]? {
        renderQueue.sync {
            let s = state.withLock { $0 }
            guard w > 0, h > 0, let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: metalLayer.pixelFormat, width: w, height: h, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            _ = encode(s, into: texture, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            var packed = [UInt32](repeating: 0, count: w * h)
            texture.getBytes(&packed, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            return packed
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

    struct ColorParams: Equatable {
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
