import Metal

/// Enlarges the remote picture exactly 2× (Actual Size on a Retina screen)
/// with a small convolutional network trained on macOS text: CoreText drawn
/// at 1× and natively at 2× with the same layout (tools/text-upscaler).
/// Against the native 2× rendering of the test pattern it scores higher than
/// FSR on every text region (SSIM 0.955 → 0.972 on light text, 0.941 →
/// 0.965 on dark text, 0.957 → 0.978 on colored text): glyphs come out
/// closer to how a Retina screen draws them, without nearest-neighbor steps
/// or a blur.
///
/// The network sees luma only: 5×5 conv 1→8, two 3×3 convs 8→8 (ReLU), a
/// 3×3 conv 8→4 whose four channels are the 2×2 sub-pixels added to a
/// bilinear 2× enlargement (1,640 multiply-adds per source pixel). The
/// compose pass (VideoView) adds that detail to the bilinear-enlarged RGB,
/// which changes luma and keeps chroma. Half precision, feature maps of two
/// RGBA slices; only the visible part of the picture is computed.
///
/// A still screen still delivers 60 frames a second. Each frame, a compare
/// pass checks the region's luma against the network's last input, per
/// threadgroup-sized tile; the network runs only on tiles that changed and
/// their neighbors. An unchanged picture costs one read of the region, and
/// typing or a moving pointer a few tiles.
final class TextUpscaler {
    private let device: MTLDevice
    private let conv1: MTLComputePipelineState
    private let conv8: MTLComputePipelineState
    private let conv4: MTLComputePipelineState
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

    /// Context each output pixel needs beyond its own source pixel (the
    /// receptive field is 11×11); the region's edges are zero-padded.
    static let margin = 5

    init?(device: MTLDevice) {
        self.device = device
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let f1 = library.makeFunction(name: "sr_conv1"), let f8 = library.makeFunction(name: "sr_conv8"),
              let f4 = library.makeFunction(name: "sr_conv4"), let fc = library.makeFunction(name: "sr_compare"),
              let p1 = try? device.makeComputePipelineState(function: f1),
              let p8 = try? device.makeComputePipelineState(function: f8),
              let p4 = try? device.makeComputePipelineState(function: f4),
              let pc = try? device.makeComputePipelineState(function: fc) else { return nil }
        conv1 = p1
        conv8 = p8
        conv4 = p4
        compare = pc
        typealias W = TextUpscalerWeights
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
        let arrays: [[Float]] = [W.c1Weight, W.c1Bias, regroup(W.c2Weight, outputs: 8), W.c2Bias,
                                 regroup(W.c3Weight, outputs: 8), W.c3Bias, regroup(W.c4Weight, outputs: 4), W.c4Bias]
        var buffers = [MTLBuffer]()
        for a in arrays {
            let half = a.map { Float16($0) }
            guard let b = half.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { return nil }
            buffers.append(b)
        }
        weights = buffers
    }

    /// Encodes the network over source pixels [origin, origin + size) of
    /// `rgb` (the converted frame); returns the sub-pixel detail texture for
    /// that region (recomputed on the GPU only where the picture changed
    /// since the last run, see above).
    func encode(rgb: MTLTexture, origin: SIMD2<Int32>, width: Int, height: Int,
                commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let threads = Self.threadgroup(for: [compare, conv1, conv8, conv4])
        let groups = MTLSize(width: (width + threads.width - 1) / threads.width, height: (height + threads.height - 1) / threads.height, depth: 1)
        if features?.0.width != width || features?.0.height != height {
            func make(_ type: MTLTextureType, slices: Int) -> MTLTexture? {
                let d = MTLTextureDescriptor()
                d.textureType = type
                d.pixelFormat = .rgba16Float
                d.width = width
                d.height = height
                d.arrayLength = slices
                d.usage = [.shaderRead, .shaderWrite]
                d.storageMode = .private
                return device.makeTexture(descriptor: d)
            }
            let lumaDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: width, height: height, mipmapped: false)
            lumaDescriptor.usage = [.shaderRead, .shaderWrite]
            lumaDescriptor.storageMode = .private
            guard let a = make(.type2DArray, slices: 2), let b = make(.type2DArray, slices: 2), let c = make(.type2DArray, slices: 2),
                  let r = make(.type2D, slices: 1), let l = device.makeTexture(descriptor: lumaDescriptor),
                  let flags = device.makeBuffer(length: groups.width * groups.height * 4, options: .storageModePrivate) else {
                features = nil
                return nil
            }
            features = (a, b, c)
            detail = r
            input = l
            changed = flags
            region = nil
        }
        guard let (a, b, c) = features, let detail, let input, let changed,
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        // Every tile starts dirty for a new region (no valid detail yet) and
        // clean otherwise; the compare marks the tiles that changed.
        let same = region.map { $0.origin == origin && $0.width == width && $0.height == height } == true
        blit.fill(buffer: changed, range: 0..<changed.length, value: same ? 0 : 1)
        blit.endEncoding()
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        region = (origin, width, height)
        var origin = origin
        var frame = SIMD2<Int32>(Int32(rgb.width), Int32(rgb.height))
        encoder.setComputePipelineState(compare)
        encoder.setTexture(rgb, index: 0)
        encoder.setTexture(input, index: 1)
        encoder.setBuffer(changed, offset: 0, index: 0)
        encoder.setBytes(&origin, length: MemoryLayout<SIMD2<Int32>>.size, index: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        func pass(_ pipeline: MTLComputePipelineState, _ source: MTLTexture, _ output: MTLTexture, _ w: Int) {
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setTexture(input, index: 2)
            encoder.setBuffer(weights[w], offset: 0, index: 0)
            encoder.setBuffer(weights[w + 1], offset: 0, index: 1)
            encoder.setBytes(&origin, length: MemoryLayout<SIMD2<Int32>>.size, index: 2)
            encoder.setBytes(&frame, length: MemoryLayout<SIMD2<Int32>>.size, index: 3)
            encoder.setBuffer(changed, offset: 0, index: 4)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        }
        pass(conv1, rgb, a, 0)
        pass(conv8, a, b, 2)
        pass(conv8, b, c, 4)
        pass(conv4, c, detail, 6)
        encoder.endEncoding()
        return detail
    }

    /// 16×16 threads where every pipeline allows it, else 8×8.
    static func threadgroup(for pipelines: [MTLComputePipelineState]) -> MTLSize {
        pipelines.allSatisfy { $0.maxTotalThreadsPerThreadgroup >= 256 }
            ? MTLSize(width: 16, height: 16, depth: 1) : MTLSize(width: 8, height: 8, depth: 1)
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

    // A tile (one threadgroup) is recomputed when it or a neighbor changed:
    // every layer's output depends on input up to 5 px away (less than a
    // tile), and a skipped tile keeps each layer's previous output.
    static bool tile_dirty(device atomic_uint *changed, uint2 tg, uint2 tiles) {
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                int2 t = int2(tg) + int2(dx, dy);
                if (t.x < 0 || t.y < 0 || t.x >= int(tiles.x) || t.y >= int(tiles.y)) continue;
                if (atomic_load_explicit(&changed[t.y * int(tiles.x) + t.x], memory_order_relaxed) != 0) return true;
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
                           uint2 gid [[thread_position_in_grid]],
                           uint2 tg [[threadgroup_position_in_grid]], uint2 tiles [[threadgroups_per_grid]]) {
        if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;
        int2 q = origin + int2(gid);
        if (q.x >= int(rgb.get_width()) || q.y >= int(rgb.get_height())) return;
        if (luma(rgb.read(uint2(q)).rgb) != input.read(gid).r)
            atomic_store_explicit(&changed[tg.y * tiles.x + tg.x], 1u, memory_order_relaxed);
    }

    kernel void sr_conv1(texture2d<half, access::read> rgb [[texture(0)]],
                         texture2d_array<half, access::write> out [[texture(1)]],
                         texture2d<half, access::write> input [[texture(2)]],
                         constant half *w [[buffer(0)]], constant half *b [[buffer(1)]],
                         constant int2 &origin [[buffer(2)]], constant int2 &frame [[buffer(3)]],
                         device atomic_uint *changed [[buffer(4)]],
                         uint2 gid [[thread_position_in_grid]],
                         uint2 tg [[threadgroup_position_in_grid]], uint2 tiles [[threadgroups_per_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        if (!tile_dirty(changed, tg, tiles)) return;
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
                         uint2 gid [[thread_position_in_grid]],
                         uint2 tg [[threadgroup_position_in_grid]], uint2 tiles [[threadgroups_per_grid]]) {
        if (gid.x >= in.get_width() || gid.y >= in.get_height()) return;
        if (!tile_dirty(changed, tg, tiles)) return;
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

    kernel void sr_conv4(texture2d_array<half, access::read> in [[texture(0)]],
                         texture2d<half, access::write> out [[texture(1)]],
                         constant half4 *w [[buffer(0)]], constant half *b [[buffer(1)]],
                         constant int2 &origin [[buffer(2)]], constant int2 &frame [[buffer(3)]],
                         device atomic_uint *changed [[buffer(4)]],
                         uint2 gid [[thread_position_in_grid]],
                         uint2 tg [[threadgroup_position_in_grid]], uint2 tiles [[threadgroups_per_grid]]) {
        if (gid.x >= in.get_width() || gid.y >= in.get_height()) return;
        if (!tile_dirty(changed, tg, tiles)) return;
        half4 a = half4(b[0], b[1], b[2], b[3]);
        for (int k = 0; k < 9; k++) {
            int2 q = int2(gid) + int2(k % 3 - 1, k / 3 - 1);
            half4 v0 = feature(in, q, 0, origin, frame), v1 = feature(in, q, 1, origin, frame);
            for (int o = 0; o < 4; o++) a[o] += dot(w[(o * 9 + k) * 2], v0) + dot(w[(o * 9 + k) * 2 + 1], v1);
        }
        out.write(a, gid);
    }
    """
}
