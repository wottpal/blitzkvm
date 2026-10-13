import JetKVMCore
import Metal

/// Enlarges the remote picture by any factor above 1× (up to `maxScale`)
/// with a small convolutional network trained on macOS text: CoreText drawn
/// at 1× and at the target scale (2.5067×, a 2400×1012 remote full screen
/// on a 40" 6016×2538 display), the glyphs where the 1× renderer put them.
/// Against that rendering it scores 25.1 dB / SSIM 0.975 on light text
/// where FSR 1 scores 22.3 dB / 0.946; at 1.5× and 2× its text average is
/// above both FSR's and the earlier 2× network's.
///
/// The network sees luma only and runs at source resolution: 5×5 conv
/// 1→8, two 3×3 convs 8→8 (ReLU), a 3×3 conv 8→n² whose channels are an
/// n×n grid of sub-pixel luma detail per source pixel (n = 3: 2,000
/// multiply-adds per source pixel). They are written as one half-float
/// image n times the region's size. The compose pass (`compose_fragment`)
/// gives each output pixel the area-weighted mean of the sub-pixels its
/// footprint covers (2–3 per axis at 2.5×), added to a bilinear enlargement
/// of the RGB picture: luma changes, chroma stays. Training sees exactly
/// this resampling, at the scale's real sub-pixel phases. At a scale of
/// exactly n, each output pixel is one sub-pixel: with n = 2 and the
/// earlier 2× weights this is bit for bit the earlier 2× upscaler.
///
/// Each time it runs, a compare pass checks the luma of the tiles that may
/// have changed (the caller knows where the frame changed) against the
/// network's last input, per threadgroup-sized tile; the network runs only
/// on tiles that changed and their neighbors. Typing or a moving pointer
/// costs a few tiles, an unchanged picture nothing.
final class TextUpscaler {
    struct Weights {
        var n: Int
        var c1, b1, c2, b2, c3, b3, c4, b4: [Float]

        static let bundled = Weights(n: TextUpscalerWeights.n,
                                     c1: TextUpscalerWeights.c1Weight, b1: TextUpscalerWeights.c1Bias,
                                     c2: TextUpscalerWeights.c2Weight, b2: TextUpscalerWeights.c2Bias,
                                     c3: TextUpscalerWeights.c3Weight, b3: TextUpscalerWeights.c3Bias,
                                     c4: TextUpscalerWeights.c4Weight, b4: TextUpscalerWeights.c4Bias)
    }

    /// Sub-pixels per source pixel and axis.
    let n: Int
    /// The compose pass; VideoView pairs it with its quad vertex function.
    let composeFunction: MTLFunction
    private let device: MTLDevice
    private let conv1: MTLComputePipelineState
    private let conv8: MTLComputePipelineState
    private let convN: MTLComputePipelineState
    private let compare: MTLComputePipelineState
    private let weights: [MTLBuffer]
    /// One feature map per layer: a tile the network skips keeps every
    /// layer's previous output, which its recomputed neighbors read.
    private var features: (MTLTexture, MTLTexture, MTLTexture)?
    private var detail: MTLTexture?
    /// The luma the network last ran on, and one "changed since" flag per
    /// threadgroup-sized tile.
    private var input: MTLTexture?
    private var changed: MTLBuffer?
    /// The source region `detail` covers.
    private var region: (origin: SIMD2<Int32>, width: Int, height: Int)?

    /// Context each output pixel needs beyond its own source pixel: the
    /// receptive field is 11×11, and a footprint reaches one pixel further.
    static let margin = 6
    /// Above this, FSR: the sub-pixel grid would be coarser than the output.
    static let maxScale = 3.0

    init?(device: MTLDevice, weights w: Weights = .bundled) {
        self.device = device
        n = w.n
        let k = w.n * w.n
        let options = MTLCompileOptions()
        options.preprocessorMacros = ["SR_N": NSNumber(value: w.n), "SR_K": NSNumber(value: k), "SR_SLICES": NSNumber(value: (k + 3) / 4)]
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: options),
              let f1 = library.makeFunction(name: "sr_conv1"), let f8 = library.makeFunction(name: "sr_conv8"),
              let fn = library.makeFunction(name: "sr_convN"), let fc = library.makeFunction(name: "sr_compare"),
              let fragment = library.makeFunction(name: "compose_fragment"),
              let p1 = try? device.makeComputePipelineState(function: f1),
              let p8 = try? device.makeComputePipelineState(function: f8),
              let pn = try? device.makeComputePipelineState(function: fn),
              let pc = try? device.makeComputePipelineState(function: fc) else { return nil }
        conv1 = p1
        conv8 = p8
        convN = pn
        compare = pc
        composeFunction = fragment
        // 3×3 layers regrouped for half4 dot products over input slices:
        // [out][tap][input slice] × 4 input channels.
        func regroup(_ w: [Float], outputs: Int) -> [Float] {
            var r = [Float]()
            for o in 0..<outputs {
                for k in 0..<9 {
                    for slice in 0..<2 {
                        for c in 0..<4 { r.append(w[(o * 8 + slice * 4 + c) * 9 + k]) }
                    }
                }
            }
            return r
        }
        let paddedBias = w.b4 + [Float](repeating: 0, count: (k + 3) / 4 * 4 - k)
        let arrays: [[Float]] = [w.c1, w.b1, regroup(w.c2, outputs: 8), w.b2, regroup(w.c3, outputs: 8), w.b3,
                                 regroup(w.c4, outputs: k), paddedBias]
        var buffers = [MTLBuffer]()
        for a in arrays {
            let half = a.map { Float16($0) }
            guard let b = half.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { return nil }
            buffers.append(b)
        }
        weights = buffers
    }

    /// Encodes the network over source pixels [origin, origin + size) of
    /// `rgb` (the converted frame); returns the sub-pixel luma detail, an
    /// image n times the region's size (recomputed on the GPU only where the
    /// picture changed since the last run, see above). `dirty` holds the
    /// frame pixels that may differ from the last run's (nil: any): only the
    /// tiles they touch are compared, and only those and their neighbors
    /// dispatched.
    func encode(rgb: MTLTexture, origin: SIMD2<Int32>, width: Int, height: Int, dirty: PixelRect? = nil,
                commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let threads = Self.threadgroup(for: [compare, conv1, conv8, convN])
        let tiles = PixelRect(width: width, height: height).cells(of: threads.width)
        if features?.0.width != width || features?.0.height != height {
            func make(_ format: MTLPixelFormat, _ w: Int, _ h: Int, slices: Int) -> MTLTexture? {
                let d = MTLTextureDescriptor()
                d.textureType = slices > 1 ? .type2DArray : .type2D
                d.pixelFormat = format
                d.width = w
                d.height = h
                d.arrayLength = slices
                d.usage = [.shaderRead, .shaderWrite]
                d.storageMode = .private
                return device.makeTexture(descriptor: d)
            }
            guard let a = make(.rgba16Float, width, height, slices: 2), let b = make(.rgba16Float, width, height, slices: 2),
                  let c = make(.rgba16Float, width, height, slices: 2), let r = make(.r16Float, width * n, height * n, slices: 1),
                  let l = make(.r16Float, width, height, slices: 1),
                  let flags = device.makeBuffer(length: tiles.width * tiles.height * 4, options: .storageModePrivate) else {
                features = nil
                return nil
            }
            features = (a, b, c)
            detail = r
            input = l
            changed = flags
            region = nil
        }
        guard let (a, b, c) = features, let detail, let input, let changed else { return nil }
        // Every tile starts dirty for a new region (no valid detail yet) and
        // clean otherwise; the compare marks the tiles that changed, of those
        // `dirty` touches, and the network runs over them and their neighbors.
        let same = region.map { $0.origin == origin && $0.width == width && $0.height == height } == true
        let touched = dirty.map { $0.offsetBy(dx: -Int(origin.x), dy: -Int(origin.y)).cells(of: threads.width).intersection(tiles) } ?? tiles
        let compared = same ? touched : .empty
        let recomputed = same ? touched.outset(by: 1).intersection(tiles) : tiles
        guard !recomputed.isEmpty else { return detail }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.fill(buffer: changed, range: 0..<changed.length, value: same ? 0 : 1)
        blit.endEncoding()
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        region = (origin, width, height)
        var origin = origin
        var frame = SIMD2<Int32>(Int32(rgb.width), Int32(rgb.height))
        // The tiles a dispatch covers, of all the region's.
        func dispatch(_ pipeline: MTLComputePipelineState, over range: PixelRect) {
            var t = Tiles(first: SIMD2(UInt32(range.x0), UInt32(range.y0)), count: SIMD2(UInt32(tiles.width), UInt32(tiles.height)))
            encoder.setComputePipelineState(pipeline)
            encoder.setBytes(&t, length: MemoryLayout<Tiles>.stride, index: 5)
            encoder.dispatchThreadgroups(MTLSize(width: range.width, height: range.height, depth: 1), threadsPerThreadgroup: threads)
        }
        if !compared.isEmpty {
            encoder.setTexture(rgb, index: 0)
            encoder.setTexture(input, index: 1)
            encoder.setBuffer(changed, offset: 0, index: 0)
            encoder.setBytes(&origin, length: MemoryLayout<SIMD2<Int32>>.size, index: 1)
            dispatch(compare, over: compared)
        }
        func pass(_ pipeline: MTLComputePipelineState, _ source: MTLTexture, _ output: MTLTexture, _ w: Int) {
            encoder.setTexture(source, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setTexture(input, index: 2)
            encoder.setBuffer(weights[w], offset: 0, index: 0)
            encoder.setBuffer(weights[w + 1], offset: 0, index: 1)
            encoder.setBytes(&origin, length: MemoryLayout<SIMD2<Int32>>.size, index: 2)
            encoder.setBytes(&frame, length: MemoryLayout<SIMD2<Int32>>.size, index: 3)
            encoder.setBuffer(changed, offset: 0, index: 4)
            dispatch(pipeline, over: recomputed)
        }
        pass(conv1, rgb, a, 0)
        pass(conv8, a, b, 2)
        pass(conv8, b, c, 4)
        pass(convN, c, detail, 6)
        encoder.endEncoding()
        return detail
    }

    /// Mirrors `Tiles` in the shader.
    private struct Tiles {
        var first: SIMD2<UInt32>
        var count: SIMD2<UInt32>
    }

    /// 16×16 threads where every pipeline allows it, else 8×8.
    static func threadgroup(for pipelines: [MTLComputePipelineState]) -> MTLSize {
        pipelines.allSatisfy { $0.maxTotalThreadsPerThreadgroup >= 256 }
            ? MTLSize(width: 16, height: 16, depth: 1) : MTLSize(width: 8, height: 8, depth: 1)
    }

    /// Mirrors `ComposeParams` in the shader (40 bytes).
    struct ComposeParams {
        var origin: SIMD2<Float>        // the video's top-left in the drawable (pixels)
        var regionOrigin: SIMD2<Int32>  // source pixel of detail's first sub-pixel block
        var frame: SIMD2<Int32>         // source size
        var invScale: SIMD2<Float>      // source pixels per drawable pixel, per axis
        var taps: Int32                 // sub-pixels per axis a footprint can touch
        var _pad: Int32 = 0

        init(origin: SIMD2<Float>, regionOrigin: SIMD2<Int32>, frame: SIMD2<Int32>, scale: SIMD2<Double>, n: Int) {
            self.origin = origin
            self.regionOrigin = regionOrigin
            self.frame = frame
            invScale = SIMD2(Float(1 / scale.x), Float(1 / scale.y))
            taps = Int32((Double(n) / min(scale.x, scale.y)).rounded(.up)) + 1
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // Feature maps are zero beyond the frame (as in training) and beyond the
    // computed region (only its margin depends on that).
    static half4 feature(texture2d_array<half, access::read> t, int2 q, uint slice, int2 origin, int2 frame) {
        int2 f = origin + q;
        bool ok = q.x >= 0 && q.y >= 0 && q.x < int(t.get_width()) && q.y < int(t.get_height()) &&
                  f.x >= 0 && f.y >= 0 && f.x < frame.x && f.y < frame.y;
        return ok ? t.read(uint2(q), slice) : half4(0.0h);
    }

    static half luma(half3 c) { return dot(c, half3(0.299h, 0.587h, 0.114h)); }

    // A dispatch covers tiles [first, first + threadgroups_per_grid) of the
    // region's `count`, one threadgroup a tile.
    struct Tiles { uint2 first; uint2 count; };

    // A tile is recomputed when it or a neighbor changed: every layer's
    // output depends on input up to 5 px away (less than a tile), and a
    // skipped tile keeps each layer's previous output.
    static bool tile_dirty(device atomic_uint *changed, uint2 tile, uint2 count) {
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                int2 t = int2(tile) + int2(dx, dy);
                if (t.x < 0 || t.y < 0 || t.x >= int(count.x) || t.y >= int(count.y)) continue;
                if (atomic_load_explicit(&changed[t.y * int(count.x) + t.x], memory_order_relaxed) != 0) return true;
            }
        }
        return false;
    }

    // Marks the tiles whose luma differs from the network's last input.
    // (Dispatches in one encoder run in order, so the network sees them.)
    kernel void sr_compare(texture2d<half, access::read> rgb [[texture(0)]],
                           texture2d<half, access::read> input [[texture(1)]],
                           device atomic_uint *changed [[buffer(0)]],
                           constant int2 &origin [[buffer(1)]],
                           constant Tiles &tiles [[buffer(5)]], uint2 tg [[threadgroup_position_in_grid]],
                           uint2 lid [[thread_position_in_threadgroup]], uint2 size [[threads_per_threadgroup]]) {
        uint2 tile = tiles.first + tg, gid = tile * size + lid;
        if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;
        int2 q = origin + int2(gid);
        if (q.x >= int(rgb.get_width()) || q.y >= int(rgb.get_height())) return;
        if (luma(rgb.read(uint2(q)).rgb) != input.read(gid).r)
            atomic_store_explicit(&changed[tile.y * tiles.count.x + tile.x], 1u, memory_order_relaxed);
    }

    kernel void sr_conv1(texture2d<half, access::read> rgb [[texture(0)]],
                         texture2d_array<half, access::write> out [[texture(1)]],
                         texture2d<half, access::write> input [[texture(2)]],
                         constant half *w [[buffer(0)]], constant half *b [[buffer(1)]],
                         constant int2 &origin [[buffer(2)]], constant int2 &frame [[buffer(3)]],
                         device atomic_uint *changed [[buffer(4)]],
                         constant Tiles &tiles [[buffer(5)]], uint2 tg [[threadgroup_position_in_grid]],
                         uint2 lid [[thread_position_in_threadgroup]], uint2 size [[threads_per_threadgroup]]) {
        uint2 tile = tiles.first + tg, gid = tile * size + lid;
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        if (!tile_dirty(changed, tile, tiles.count)) return;
        int2 p = origin + int2(gid);
        half4 a0 = half4(b[0], b[1], b[2], b[3]), a1 = half4(b[4], b[5], b[6], b[7]);
        for (int k = 0; k < 25; k++) {
            int2 q = p + int2(k % 5 - 2, k / 5 - 2);
            bool in = q.x >= 0 && q.y >= 0 && q.x < frame.x && q.y < frame.y;
            half y = in ? luma(rgb.read(uint2(q)).rgb) : 0.0h;
            a0 += y * half4(w[k], w[25 + k], w[50 + k], w[75 + k]);
            a1 += y * half4(w[100 + k], w[125 + k], w[150 + k], w[175 + k]);
            if (k == 12) input.write(half4(y), gid);
        }
        out.write(max(a0, 0.0h), gid, 0);
        out.write(max(a1, 0.0h), gid, 1);
    }

    // 3x3 over 8 channels: out[o] = b[o] + the taps' dot products over the
    // two input slices.
    kernel void sr_conv8(texture2d_array<half, access::read> in [[texture(0)]],
                         texture2d_array<half, access::write> out [[texture(1)]],
                         constant half4 *w [[buffer(0)]], constant half *b [[buffer(1)]],
                         constant int2 &origin [[buffer(2)]], constant int2 &frame [[buffer(3)]],
                         device atomic_uint *changed [[buffer(4)]],
                         constant Tiles &tiles [[buffer(5)]], uint2 tg [[threadgroup_position_in_grid]],
                         uint2 lid [[thread_position_in_threadgroup]], uint2 size [[threads_per_threadgroup]]) {
        uint2 tile = tiles.first + tg, gid = tile * size + lid;
        if (gid.x >= in.get_width() || gid.y >= in.get_height()) return;
        if (!tile_dirty(changed, tile, tiles.count)) return;
        half4 a0 = half4(b[0], b[1], b[2], b[3]), a1 = half4(b[4], b[5], b[6], b[7]);
        for (int k = 0; k < 9; k++) {
            int2 q = int2(gid) + int2(k % 3 - 1, k / 3 - 1);
            half4 v0 = feature(in, q, 0, origin, frame), v1 = feature(in, q, 1, origin, frame);
            for (int o = 0; o < 4; o++) {
                a0[o] += dot(w[(o * 9 + k) * 2], v0) + dot(w[(o * 9 + k) * 2 + 1], v1);
                a1[o] += dot(w[((o + 4) * 9 + k) * 2], v0) + dot(w[((o + 4) * 9 + k) * 2 + 1], v1);
            }
        }
        out.write(max(a0, 0.0h), gid, 0);
        out.write(max(a1, 0.0h), gid, 1);
    }

    // 3x3 over 8 channels to this source pixel's SR_N x SR_N sub-pixels
    // (output o = sub-pixel (o % SR_N, o / SR_N)), written into the detail
    // image SR_N times the region's size.
    kernel void sr_convN(texture2d_array<half, access::read> in [[texture(0)]],
                         texture2d<half, access::write> out [[texture(1)]],
                         constant half4 *w [[buffer(0)]], constant half4 *b [[buffer(1)]],
                         constant int2 &origin [[buffer(2)]], constant int2 &frame [[buffer(3)]],
                         device atomic_uint *changed [[buffer(4)]],
                         constant Tiles &tiles [[buffer(5)]], uint2 tg [[threadgroup_position_in_grid]],
                         uint2 lid [[thread_position_in_threadgroup]], uint2 size [[threads_per_threadgroup]]) {
        uint2 tile = tiles.first + tg, gid = tile * size + lid;
        if (gid.x >= in.get_width() || gid.y >= in.get_height()) return;
        if (!tile_dirty(changed, tile, tiles.count)) return;
        half4 a[SR_SLICES];
        for (int s = 0; s < SR_SLICES; s++) a[s] = b[s];
        for (int k = 0; k < 9; k++) {
            int2 q = int2(gid) + int2(k % 3 - 1, k / 3 - 1);
            half4 v0 = feature(in, q, 0, origin, frame), v1 = feature(in, q, 1, origin, frame);
            for (int o = 0; o < SR_K; o++) a[o >> 2][o & 3] += dot(w[(o * 9 + k) * 2], v0) + dot(w[(o * 9 + k) * 2 + 1], v1);
        }
        for (int o = 0; o < SR_K; o++) out.write(half4(a[o >> 2][o & 3]), gid * SR_N + uint2(o % SR_N, o / SR_N));
    }

    struct VOut { float4 position [[position]]; };
    struct ComposeParams { float2 origin; int2 regionOrigin; int2 frame; float2 invScale; int taps; int _pad; };

    // Bilinear RGB plus the area-weighted mean of the sub-pixel luma detail
    // under this drawable pixel's footprint [j, j + 1) / scale (luma changes,
    // chroma stays). Sub-pixels beyond the frame repeat its edge.
    fragment float4 compose_fragment(VOut in [[stage_in]],
                                     texture2d<float> rgb [[texture(0)]],
                                     texture2d<half, access::read> detail [[texture(1)]],
                                     sampler s [[sampler(0)]],
                                     constant ComposeParams &p [[buffer(0)]]) {
        float2 d = in.position.xy - p.origin;
        float3 c = rgb.sample(s, d * p.invScale / float2(rgb.get_width(), rgb.get_height())).rgb;
        float2 k = p.invScale * float(SR_N);
        float2 lo = (d - 0.5) * k, hi = (d + 0.5) * k;
        int2 m0 = int2(floor(lo));
        int2 last = p.frame * SR_N - 1, base = p.regionOrigin * SR_N;
        float r = 0.0;
        for (int ty = 0; ty < p.taps; ty++) {
            int my = m0.y + ty;
            float wy = min(hi.y, float(my + 1)) - max(lo.y, float(my));
            if (wy <= 0.0) break;
            float row = 0.0;
            for (int tx = 0; tx < p.taps; tx++) {
                int mx = m0.x + tx;
                float wx = min(hi.x, float(mx + 1)) - max(lo.x, float(mx));
                if (wx <= 0.0) break;
                row += wx * float(detail.read(uint2(clamp(int2(mx, my), int2(0), last) - base)).r);
            }
            r += wy * row;
        }
        r /= (hi.x - lo.x) * (hi.y - lo.y);
        return float4(saturate(c + r), 1.0);
    }
    """
}
