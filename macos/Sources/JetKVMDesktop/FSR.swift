import simd

// AMD FidelityFX Super Resolution 1.0 (EASU upscaling + RCAS sharpening),
// ported to Metal: edge-adaptive upscaling keeps remote text crisp at any
// scale without the stair steps of nearest-neighbor or the blur of bilinear.
// Verified against upstream FsrEasuCon/FsrRcasCon (bit-identical constants)
// and a CPU reference (within one half-float step); no half-pixel shift.
// MIT license, see the header of `source`.
enum FSR {
    static let source = #"""
//==============================================================================================================================
// AMD FidelityFX SUPER RESOLUTION [FSR 1] - EASU + RCAS, 32-bit float paths, ported to Metal Shading Language.
//
// Port of ffx_fsr1.h / ffx_a.h v1.20210629 from https://github.com/GPUOpen-Effects/FidelityFX-FSR (ffx-fsr/).
// Ported functions: FsrEasuF (+FsrEasuTapF, FsrEasuSetF), FsrRcasF, and the approximations they use from ffx_a.h
// (APrxLoRcpF1, APrxLoRsqF1, APrxMedRcpF1). The CPU-side FsrEasuCon / FsrRcasCon are at the end of FSR.swift.
// Self-contained: no includes beyond <metal_stdlib>; safe to embed as a Swift string and compile at runtime.
//
// Original copyright and license (ffx_fsr1.h and ffx_a.h):
//------------------------------------------------------------------------------------------------------------------------------
// FidelityFX Super Resolution Sample
//
// Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//------------------------------------------------------------------------------------------------------------------------------
// ffx_a.h additionally carries (for the "FLOAT APPROXIMATIONS" used below):
// MIT LICENSE - Copyright (c) 2014 Michal Drobot (for concepts used in "FLOAT APPROXIMATIONS").
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//==============================================================================================================================
//
// Input: gamma-encoded (sRGB-like) RGB in [0,1]. Pipeline: EASU (scale) -> intermediate texture -> RCAS (1:1) -> drawable.
// Metal port notes:
//  - Metal gather() returns texels in the same order as HLSL Gather / GLSL textureGather:
//    x=(-,+) y=(+,+) z=(+,-) w=(-,-), i.e. bottom-left, bottom-right, top-right, top-left of the 2x2 footprint
//    (v grows downward in both APIs), so the upstream bczz/ijfe/klhg/zzon swizzles are used unchanged.
//  - The approximations are bit tricks via as_type<>, exactly like upstream; they also keep EASU free of inf/NaN
//    (APrxLoRcpF1(0) is a large finite number, so 0*rcp(0) == 0), which matters because Metal compiles with fast math.
//  - RCAS relies on D3D's NaN-dropping max() when a limiter is 0/0 (a channel that is all-0 or all-1 in the cross).
//    Metal fast math gives no NaN guarantees, so those cases are selected explicitly (same result as upstream on AMD).
//  - RCAS uses read() with clamped coordinates (D3D Load returns 0 out of bounds; Metal read() is undefined there).
//==============================================================================================================================
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 position [[position]]; };

// Rect quad: rect.xy = NDC origin (bottom-left), rect.zw = NDC size. Draw as triangle strip, 4 vertices.
vertex VOut fsr_rect_vertex(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
    float2 c = float2(float(vid & 1u), float(vid >> 1u));
    VOut o;
    o.position = float4(rect.xy + c * rect.zw, 0.0, 1.0);
    return o;
}

//------------------------------------------------------------------------------------------------------------------------------
// ffx_a.h approximations (Drobot). Same magic constants, same integer-subtract formulation.
static inline float APrxLoRcpF1(float a)  { return as_type<float>(0x7ef07ebbu - as_type<uint>(a)); }
static inline float APrxLoRsqF1(float a)  { return as_type<float>(0x5f347d74u - (as_type<uint>(a) >> 1u)); }
static inline float APrxMedRcpF1(float a) { float b = as_type<float>(0x7ef19fffu - as_type<uint>(a)); return b * (-b * a + 2.0f); }

//==============================================================================================================================
//                                          [EASU] EDGE ADAPTIVE SPATIAL UPSAMPLING
//==============================================================================================================================
// con0..con3 exactly as produced by FsrEasuCon (bit-identical as floats). An output that sits at 'origin' inside a larger
// drawable is handled CPU-side by folding the origin into con0.zw (see easuConstants), so ip below is the drawable pixel.
struct EasuParams { float4 con0; float4 con1; float4 con2; float4 con3; };

// FsrEasuTapF
static inline void FsrEasuTapF(thread float3 &aC, thread float &aW, float2 off, float2 dir, float2 len,
                               float lob, float clp, float3 c) {
    // Rotate offset by direction.
    float2 v;
    v.x = (off.x * ( dir.x)) + (off.y * dir.y);
    v.y = (off.x * (-dir.y)) + (off.y * dir.x);
    // Anisotropy.
    v *= len;
    // Compute distance^2.
    float d2 = v.x * v.x + v.y * v.y;
    // Limit to the window as at corner, 2 taps can easily be outside.
    d2 = min(d2, clp);
    // Approximation of lanczos2 without sin() or rcp(), or sqrt() to get x.
    //  (25/16 * (2/5 * x^2 - 1)^2 - (25/16 - 1)) * (1/4 * x^2 - 1)^2
    float wB = (2.0f / 5.0f) * d2 - 1.0f;
    float wA = lob * d2 - 1.0f;
    wB *= wB;
    wA *= wA;
    wB = (25.0f / 16.0f) * wB - (25.0f / 16.0f - 1.0f);
    float w = wB * wA;
    // Do weighted average.
    aC += c * w;
    aW += w;
}

// FsrEasuSetF. Upstream selects the bilinear weight via compile-time bools (biS/biT/biU/biV); the caller passes it here.
//    a
//  b c d
//    e
static inline void FsrEasuSetF(thread float2 &dir, thread float &len, float w,
                               float lA, float lB, float lC, float lD, float lE) {
    // Direction is the '+' diff. Then takes magnitude from abs average of both sides of 'c'.
    // Length converts gradient reversal to 0, smoothly to non-reversal at 1, shaped, then adding horz and vert terms.
    float dc = lD - lC;
    float cb = lC - lB;
    float lenX = max(abs(dc), abs(cb));
    lenX = APrxLoRcpF1(lenX);
    float dirX = lD - lB;
    dir.x += dirX * w;
    lenX = saturate(abs(dirX) * lenX);
    lenX *= lenX;
    len += lenX * w;
    // Repeat for the y axis.
    float ec = lE - lC;
    float ca = lC - lA;
    float lenY = max(abs(ec), abs(ca));
    lenY = APrxLoRcpF1(lenY);
    float dirY = lE - lA;
    dir.y += dirY * w;
    lenY = saturate(abs(dirY) * lenY);
    lenY *= lenY;
    len += lenY * w;
}

// FsrEasuF. 'ip' is the integer output pixel position. FsrEasuRF/GF/BF = gather of component x/y/z.
static inline float3 FsrEasuF(float2 ip, EasuParams p, texture2d<float> src, sampler s) {
    // Get position of 'f'.
    float2 pp = ip * p.con0.xy + p.con0.zw;
    float2 fp = floor(pp);
    pp -= fp;
    // 12-tap kernel.
    //    b c
    //  e f g h
    //  i j k l
    //    n o
    // Gather 4 ordering.
    //  a b
    //  r g
    float2 p0 = fp * p.con1.xy + p.con1.zw;
    // These are from p0 to avoid pulling two constants on pre-Navi hardware.
    float2 p1 = p0 + p.con2.xy;
    float2 p2 = p0 + p.con2.zw;
    float2 p3 = p0 + p.con3.xy;
    float4 bczzR = src.gather(s, p0, int2(0), component::x);
    float4 bczzG = src.gather(s, p0, int2(0), component::y);
    float4 bczzB = src.gather(s, p0, int2(0), component::z);
    float4 ijfeR = src.gather(s, p1, int2(0), component::x);
    float4 ijfeG = src.gather(s, p1, int2(0), component::y);
    float4 ijfeB = src.gather(s, p1, int2(0), component::z);
    float4 klhgR = src.gather(s, p2, int2(0), component::x);
    float4 klhgG = src.gather(s, p2, int2(0), component::y);
    float4 klhgB = src.gather(s, p2, int2(0), component::z);
    float4 zzonR = src.gather(s, p3, int2(0), component::x);
    float4 zzonG = src.gather(s, p3, int2(0), component::y);
    float4 zzonB = src.gather(s, p3, int2(0), component::z);
    // Simplest multi-channel approximate luma possible (luma times 2, in 2 FMA/MAD).
    float4 bczzL = bczzB * 0.5f + (bczzR * 0.5f + bczzG);
    float4 ijfeL = ijfeB * 0.5f + (ijfeR * 0.5f + ijfeG);
    float4 klhgL = klhgB * 0.5f + (klhgR * 0.5f + klhgG);
    float4 zzonL = zzonB * 0.5f + (zzonR * 0.5f + zzonG);
    // Rename.
    float bL = bczzL.x;
    float cL = bczzL.y;
    float iL = ijfeL.x;
    float jL = ijfeL.y;
    float fL = ijfeL.z;
    float eL = ijfeL.w;
    float kL = klhgL.x;
    float lL = klhgL.y;
    float hL = klhgL.z;
    float gL = klhgL.w;
    float oL = zzonL.z;
    float nL = zzonL.w;
    // Accumulate for bilinear interpolation.
    float2 dir = float2(0.0f);
    float len = 0.0f;
    FsrEasuSetF(dir, len, (1.0f - pp.x) * (1.0f - pp.y), bL, eL, fL, gL, jL); // s
    FsrEasuSetF(dir, len,         pp.x  * (1.0f - pp.y), cL, fL, gL, hL, kL); // t
    FsrEasuSetF(dir, len, (1.0f - pp.x) *         pp.y , fL, iL, jL, kL, nL); // u
    FsrEasuSetF(dir, len,         pp.x  *         pp.y , gL, jL, kL, lL, oL); // v
    // Normalize with approximation, and cleanup close to zero.
    float2 dir2 = dir * dir;
    float dirR = dir2.x + dir2.y;
    bool zro = dirR < (1.0f / 32768.0f);
    dirR = APrxLoRsqF1(dirR);
    dirR = zro ? 1.0f : dirR;
    dir.x = zro ? 1.0f : dir.x;
    dir *= dirR;
    // Transform from {0 to 2} to {0 to 1} range, and shape with square.
    len = len * 0.5f;
    len *= len;
    // Stretch kernel {1.0 vert|horz, to sqrt(2.0) on diagonal}.
    float stretch = (dir.x * dir.x + dir.y * dir.y) * APrxLoRcpF1(max(abs(dir.x), abs(dir.y)));
    // Anisotropic length after rotation,
    //  x := 1.0 lerp to 'stretch' on edges
    //  y := 1.0 lerp to 2x on edges
    float2 len2 = float2(1.0f + (stretch - 1.0f) * len, 1.0f - 0.5f * len);
    // Based on the amount of 'edge', the window shifts from +/-{sqrt(2.0) to slightly beyond 2.0}.
    float lob = 0.5f + ((1.0f / 4.0f - 0.04f) - 0.5f) * len;
    // Set distance^2 clipping point to the end of the adjustable window.
    float clp = APrxLoRcpF1(lob);
    // Accumulation mixed with min/max of 4 nearest (f g j k).
    float3 fC = float3(ijfeR.z, ijfeG.z, ijfeB.z);
    float3 gC = float3(klhgR.w, klhgG.w, klhgB.w);
    float3 jC = float3(ijfeR.y, ijfeG.y, ijfeB.y);
    float3 kC = float3(klhgR.x, klhgG.x, klhgB.x);
    float3 min4 = min(min3(fC, gC, jC), kC);
    float3 max4 = max(max3(fC, gC, jC), kC);
    // Accumulation.
    float3 aC = float3(0.0f);
    float aW = 0.0f;
    FsrEasuTapF(aC, aW, float2( 0.0f, -1.0f) - pp, dir, len2, lob, clp, float3(bczzR.x, bczzG.x, bczzB.x)); // b
    FsrEasuTapF(aC, aW, float2( 1.0f, -1.0f) - pp, dir, len2, lob, clp, float3(bczzR.y, bczzG.y, bczzB.y)); // c
    FsrEasuTapF(aC, aW, float2(-1.0f,  1.0f) - pp, dir, len2, lob, clp, float3(ijfeR.x, ijfeG.x, ijfeB.x)); // i
    FsrEasuTapF(aC, aW, float2( 0.0f,  1.0f) - pp, dir, len2, lob, clp, jC);                                // j
    FsrEasuTapF(aC, aW, float2( 0.0f,  0.0f) - pp, dir, len2, lob, clp, fC);                                // f
    FsrEasuTapF(aC, aW, float2(-1.0f,  0.0f) - pp, dir, len2, lob, clp, float3(ijfeR.w, ijfeG.w, ijfeB.w)); // e
    FsrEasuTapF(aC, aW, float2( 1.0f,  1.0f) - pp, dir, len2, lob, clp, kC);                                // k
    FsrEasuTapF(aC, aW, float2( 2.0f,  1.0f) - pp, dir, len2, lob, clp, float3(klhgR.y, klhgG.y, klhgB.y)); // l
    FsrEasuTapF(aC, aW, float2( 2.0f,  0.0f) - pp, dir, len2, lob, clp, float3(klhgR.z, klhgG.z, klhgB.z)); // h
    FsrEasuTapF(aC, aW, float2( 1.0f,  0.0f) - pp, dir, len2, lob, clp, gC);                                // g
    FsrEasuTapF(aC, aW, float2( 1.0f,  2.0f) - pp, dir, len2, lob, clp, float3(zzonR.z, zzonG.z, zzonB.z)); // o
    FsrEasuTapF(aC, aW, float2( 0.0f,  2.0f) - pp, dir, len2, lob, clp, float3(zzonR.w, zzonG.w, zzonB.w)); // n
    // Normalize and dering.
    return min(max4, max(min4, aC * (1.0f / aW)));
}

// src: linear-filter / clamp-to-edge sampler with normalized coordinates (gather ignores the filter, not the address mode).
fragment float4 easu_fragment(VOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              sampler s [[sampler(0)]],
                              constant EasuParams &p [[buffer(0)]]) {
    return float4(FsrEasuF(floor(in.position.xy), p, src, s), 1.0f);
}

//==============================================================================================================================
//                                          [RCAS] ROBUST CONTRAST ADAPTIVE SHARPENING
//==============================================================================================================================
// This is set at the limit of providing unnatural results for sharpening.
#define FSR_RCAS_LIMIT (0.25f - (1.0f / 16.0f))

// Optional deviation from upstream (default off = faithful). In flat areas RCAS always picks lobe = -LIMIT*sharpness and
// the output is c*(4*lobe+1)*APrxMedRcpF1(4*lobe+1); that one-Newton-step reciprocal always under-estimates, so flat
// areas are darkened by 0.05..0.32% (white 255 -> 254.2 at 0 stops, 254.6 at 0.2 stops). 1 = exact divide, flat stays flat.
// Set via MTLCompileOptions.preprocessorMacros = ["FSR_RCAS_EXACT_RESOLVE": 1] or a #define before this file.
#ifndef FSR_RCAS_EXACT_RESOLVE
#define FSR_RCAS_EXACT_RESOLVE 0
#endif

// sharpness = exp2(-stops) (FsrRcasCon con[0]); origin = integer top-left of the RCAS output rect in the render target,
// so src texel = fragment pixel - origin (src is the EASU output, sized exactly to the rect).
struct RcasParams { int2 origin; float sharpness; float _pad; };

// FsrRcasF (FSR_RCAS_DENOISE and FSR_RCAS_PASSTHROUGH_ALPHA not ported). Vectorized over RGB; per-channel math unchanged.
static inline float3 FsrRcasF(int2 sp, float sharpness, texture2d<float> src) {
    // Algorithm uses minimal 3x3 pixel neighborhood.
    //    b
    //  d e f
    //    h
    int2 hi = int2(src.get_width(), src.get_height()) - 1;
    float3 b = src.read(uint2(clamp(sp + int2( 0, -1), int2(0), hi))).rgb;
    float3 d = src.read(uint2(clamp(sp + int2(-1,  0), int2(0), hi))).rgb;
    float3 e = src.read(uint2(clamp(sp,                int2(0), hi))).rgb;
    float3 f = src.read(uint2(clamp(sp + int2( 1,  0), int2(0), hi))).rgb;
    float3 h = src.read(uint2(clamp(sp + int2( 0,  1), int2(0), hi))).rgb;
    // (FsrRcasInputF: no input transform; luma/noise detection only feeds FSR_RCAS_DENOISE, so it is omitted.)
    // Min and max of ring.
    float3 mn4 = min(min3(b, d, f), h);
    float3 mx4 = max(max3(b, d, f), h);
    // Immediate constants for peak range.
    float2 peakC = float2(1.0f, -1.0f * 4.0f);
    // Limiters, these need to be high precision RCPs.
    // Upstream divides 0/0 when a channel is all-0 (hitMin) or all-1 (hitMax) and relies on max() dropping the NaN;
    // select that outcome explicitly: the NaN side never wins the max below.
    float3 hitMinDen = 4.0f * mx4;
    float3 hitMaxDen = 4.0f * mn4 + peakC.y;
    float3 hitMin = select(min(mn4, e) / hitMinDen, float3( 1e30f), hitMinDen == 0.0f);
    float3 hitMax = select((peakC.x - max(mx4, e)) / hitMaxDen, float3(-1e30f), hitMaxDen == 0.0f);
    float3 lobeRGB = max(-hitMin, hitMax);
    float lobe = max(-FSR_RCAS_LIMIT, min(max3(lobeRGB.r, lobeRGB.g, lobeRGB.b), 0.0f)) * sharpness;
    // Resolve, which needs the medium precision rcp approximation to avoid visible tonality changes.
#if FSR_RCAS_EXACT_RESOLVE
    float rcpL = 1.0f / (4.0f * lobe + 1.0f);
#else
    float rcpL = APrxMedRcpF1(4.0f * lobe + 1.0f);
#endif
    return (lobe * b + lobe * d + lobe * h + lobe * f + e) * rcpL;
}

fragment float4 rcas_fragment(VOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              constant RcasParams &p [[buffer(0)]]) {
    return float4(FsrRcasF(int2(in.position.xy) - p.origin, p.sharpness, src), 1.0f);
}
"""#

    // CPU-side constant setup for `source`: FsrEasuCon / FsrRcasCon from AMD FidelityFX Super Resolution 1.0
    // (ffx_fsr1.h v1.20210629, https://github.com/GPUOpen-Effects/FidelityFX-FSR, MIT license,
    // Copyright (c) 2021 Advanced Micro Devices, Inc. - full license text at the top of `source`).


    /// Mirrors `struct EasuParams { float4 con0, con1, con2, con3; }` in `source` (64 bytes).
    /// Upstream stores the same values as uint bit patterns (AU1_AF1); as floats they are bit-identical.
    struct EasuParams {
        var con0: SIMD4<Float>
        var con1: SIMD4<Float>
        var con2: SIMD4<Float>
        var con3: SIMD4<Float>
    }

    /// Mirrors `struct RcasParams { int2 origin; float sharpness; float _pad; }` in `source` (16 bytes).
    struct RcasParams {
        var origin: SIMD2<Int32>
        var sharpness: Float
        var _pad: Float = 0
    }

    /// FsrEasuCon with inputViewport == inputSize (whole texture is scaled), same float32 operation order as upstream.
    /// `outputOffset`: top-left of the output rect inside the render target, in target pixels (may be fractional).
    /// It is folded into con0.zw so the shader can keep using the raw target pixel position
    /// (equivalent to `ip = fragment pixel - origin`); with `.zero` the result is bit-identical to FsrEasuCon.
    static func easuConstants(inputSize: SIMD2<Float>, outputSize: SIMD2<Float>, outputOffset: SIMD2<Float> = .zero) -> EasuParams {
        let rcpOut = 1 / outputSize                  // ARcpF1(outputSizeInPixels)
        let rcpIn = 1 / inputSize                    // ARcpF1(inputSizeInPixels)
        let scale = inputSize * rcpOut               // con0.xy: output pixel -> input pixel
        var bias = 0.5 * inputSize * rcpOut - 0.5    // con0.zw: pixel-center alignment
        if outputOffset != .zero { bias -= outputOffset * scale }
        return EasuParams(
            con0: SIMD4(scale.x, scale.y, bias.x, bias.y),
            con1: SIMD4(rcpIn.x, rcpIn.y, 1.0 * rcpIn.x, -1.0 * rcpIn.y), // upper-left of 'F' -> gather center (0)
            con2: SIMD4(-1.0 * rcpIn.x, 2.0 * rcpIn.y, 1.0 * rcpIn.x, 2.0 * rcpIn.y), // (0) -> (1), (0) -> (2)
            con3: SIMD4(0.0 * rcpIn.x, 4.0 * rcpIn.y, 0, 0))                          // (0) -> (3)
    }

    /// FsrRcasCon: `sharpnessStops` 0 = maximum sharpening, each +1.0 halves it (0.2 is AMD's sample default).
    /// `outputOrigin`: integer top-left of the RCAS output rect in the render target (the EASU texture is rect-sized).
    static func rcasConstants(sharpnessStops: Float, outputOrigin: SIMD2<Int32> = .zero) -> RcasParams {
        RcasParams(origin: outputOrigin, sharpness: exp2f(-sharpnessStops))
    }
}
