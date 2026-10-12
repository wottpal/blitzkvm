import CoreVideo
import JetKVMCore
import Metal
import XCTest
@testable import BlitzKVM

/// The renderer draws only where frames changed. Its picture must be
/// bit-identical to drawing every pixel, for every filter and layout.
final class VideoViewTests: XCTestCase {
    private struct Case {
        var name: String
        /// Cycled per frame: switching filters (and the text upscaler at
        /// exactly 2×) must redraw everything.
        var filters: [ScalingFilter]
        var mode: ScalingMode = .fit
        var drawable: (Int, Int)
        /// Cycled per frame like `filters`.
        var pans: [(x: Double, y: Double)] = [(0.5, 0.5)]
        /// Left (or unspecified) sited chroma takes the guided path.
        var chromaLocation = kCVImageBufferChromaLocation_Left
    }

    // The 2400×1012 shape, smaller.
    private let width = 480, height = 202

    func testChangedRegionsRenderLikeWholeFrames() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let cases = [
            Case(name: "FSR at 2.5×", filters: [.fsr], drawable: (1204, 600)),
            Case(name: "FSR, strong sharpening", filters: [.fsrSharp], drawable: (1204, 600)),
            Case(name: "EASU alone", filters: [.easu], drawable: (1204, 600)),
            // EASU's output is its own canvas, stale after another filter.
            Case(name: "Catmull-Rom, then EASU", filters: [.catmullRom, .catmullRom, .easu, .easu], drawable: (1204, 600)),
            Case(name: "Lanczos-3", filters: [.lanczos], drawable: (1100, 520)),
            Case(name: "Catmull-Rom", filters: [.catmullRom], drawable: (1100, 520)),
            Case(name: "bilinear", filters: [.bilinear], drawable: (1100, 520)),
            Case(name: "sharp bilinear", filters: [.sharpBilinear], drawable: (1100, 520)),
            Case(name: "nearest", filters: [.nearest], drawable: (1100, 520)),
            Case(name: "shrunk", filters: [.automatic], drawable: (300, 180)),
            Case(name: "Lanczos-3 shrunk", filters: [.lanczos], drawable: (200, 120)),
            Case(name: "1:1", filters: [.automatic], mode: .pixelExact, drawable: (600, 250)),
            Case(name: "panned", filters: [.catmullRom, .catmullRom, .fsr], mode: .actualSize, drawable: (700, 300),
                 pans: [(0.3, 0.8), (0.3, 0.8), (0.3, 0.8), (0.6, 0.2)]),
            Case(name: "unguided chroma", filters: [.fsr], drawable: (1204, 600), chromaLocation: kCVImageBufferChromaLocation_TopLeft),
            // FSR's canvas must not build on a frame older than the upscaler's.
            Case(name: "text upscaler and FSR", filters: [.automatic, .fsr, .fsr, .automatic, .fsr, .easu], drawable: (960, 404)),
        ]
        var random = SplitMix64(seed: 0x5EED)
        var partial = 0
        let steps = 24
        for c in cases {
            var frame = try makeFrame(c, random: &random)
            let view = try makeView(c)
            view.display(frame)
            _ = view.renderOffscreen(width: c.drawable.0, height: c.drawable.1)
            for step in 0..<steps {
                view.scalingFilter = c.filters[step % c.filters.count]
                view.pan = c.pans[step % c.pans.count]
                // Sometimes two frames before a render: their changes add up.
                for _ in 0..<(step % 3 == 2 ? 2 : 1) {
                    frame = try changed(frame, random: &random)
                    view.display(frame)
                }
                try assertRendersLikeAWholeFrame(view, c, frame, "\(c.name), frame \(step)")
                if view.redrawnShare < 1 { partial += 1 }
            }
        }
        // Many frames drew only part of the canvas. The others drew all of
        // it: after a change of filter, pan or path (the text upscaler), and
        // for changes that reach everything (all new content, or changes far
        // apart, which are drawn as one rectangle).
        XCTAssertGreaterThan(partial, cases.count * steps / 4)
    }

    /// Frames drawn without the canvas (the text upscaler at exactly 2×)
    /// still count: the canvas must not just add the next change.
    func testCanvasCatchesUpWithFramesItDidNotDraw() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        var random = SplitMix64(seed: 3)
        let c = Case(name: "", filters: [.fsr], drawable: (960, 404))
        let view = try makeView(c)
        var frame = try makeFrame(c, random: &random)
        view.display(frame)
        _ = view.renderOffscreen(width: c.drawable.0, height: c.drawable.1)
        let steps: [(ScalingFilter, PixelRect)] = [
            (.fsr, PixelRect(x0: 10, y0: 10, x1: 30, y1: 30)),        // draws the canvas whole
            (.fsr, PixelRect(x0: 200, y0: 20, x1: 220, y1: 40)),      // part of it
            (.automatic, PixelRect(x0: 400, y0: 150, x1: 420, y1: 170)), // the text upscaler
            (.fsr, PixelRect(x0: 10, y0: 150, x1: 30, y1: 170)),
        ]
        for (step, (filter, rect)) in steps.enumerated() {
            frame = try copy(frame)
            edit(frame, plane: 0, rect: rect, random: &random)
            view.scalingFilter = filter
            view.display(frame)
            try assertRendersLikeAWholeFrame(view, c, frame, "step \(step)")
        }
    }

    private func assertRendersLikeAWholeFrame(_ view: VideoView, _ c: Case, _ frame: CVPixelBuffer, _ label: String) throws {
        let reference = try makeView(c)
        reference.scalingFilter = view.scalingFilter
        reference.pan = view.pan
        reference.display(frame)
        let got = try XCTUnwrap(view.renderOffscreen(width: c.drawable.0, height: c.drawable.1))
        let want = try XCTUnwrap(reference.renderOffscreen(width: c.drawable.0, height: c.drawable.1))
        guard memcmp(got, want, got.count * 4) != 0 else { return }
        let first = got.indices.first { got[$0] != want[$0] } ?? 0
        XCTFail("\(label): differs from a full render, first at (\(first % c.drawable.0), \(first / c.drawable.0))")
    }

    func testChangedRectFindsTheChange() throws {
        var random = SplitMix64(seed: 7)
        let c = Case(name: "", filters: [.fsr], drawable: (1, 1))
        let frame = try makeFrame(c, random: &random)
        XCTAssertEqual(VideoView.changedRect(frame, try copy(frame)), .empty)
        // Luma: exactly the changed pixels.
        for rect in [PixelRect(x0: 0, y0: 0, x1: 1, y1: 1), PixelRect(x0: 13, y0: 7, x1: 14, y1: 40),
                     PixelRect(x0: 100, y0: 50, x1: 391, y1: 51), PixelRect(x0: 470, y0: 190, x1: 480, y1: 202)] {
            let next = try copy(frame)
            edit(next, plane: 0, rect: rect, random: &random)
            XCTAssertEqual(VideoView.changedRect(frame, next), rect)
        }
        // Chroma: the 2×2 luma pixels of each changed site.
        let next = try copy(frame)
        edit(next, plane: 1, rect: PixelRect(x0: 21, y0: 9, x1: 22, y1: 10), random: &random)
        XCTAssertEqual(VideoView.changedRect(frame, next), PixelRect(x0: 42, y0: 18, x1: 44, y1: 20))
        // Other colorimetry: everything.
        let tagged = try copy(frame)
        CVBufferSetAttachment(tagged, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        XCTAssertEqual(VideoView.changedRect(frame, tagged), PixelRect(width: width, height: height))
    }

    private func makeView(_ c: Case) throws -> VideoView {
        // No window and no size: it draws only when asked to.
        let view = try XCTUnwrap(VideoView(frame: .zero))
        view.scalingMode = c.mode
        view.scalingFilter = c.filters[0]
        view.pan = c.pans[0]
        return view
    }

    private func makeFrame(_ c: Case, random: inout SplitMix64) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CVBufferSetAttachment(frame, kCVImageBufferChromaLocationTopFieldKey, c.chromaLocation, .shouldPropagate)
        CVBufferSetAttachment(frame, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        // Like a desktop: flat areas (where the chroma fit amplifies small
        // changes the most), edges between them, and noisy patches.
        for y in stride(from: 0, to: height, by: 16) {
            for x in stride(from: 0, to: width, by: 16) {
                let block = PixelRect(x0: x, y0: y, x1: x + 16, y1: y + 16).intersection(PixelRect(width: width, height: height))
                let noisy = random.next() % 4 == 0
                for (plane, rect) in [(0, block), (1, block.cells(of: 2))] {
                    edit(frame, plane: plane, rect: rect, flat: noisy ? 0 : UInt8(truncatingIfNeeded: random.next()), random: &random)
                    if noisy { edit(frame, plane: plane, rect: rect, random: &random) }
                }
            }
        }
        return frame
    }

    private func copy(_ frame: CVPixelBuffer) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, CVPixelBufferGetPixelFormatType(frame), attributes, &buffer), kCVReturnSuccess)
        let copy = try XCTUnwrap(buffer)
        CVBufferPropagateAttachments(frame, copy)
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        for plane in 0..<2 {
            let from = CVPixelBufferGetBaseAddressOfPlane(frame, plane)!, to = CVPixelBufferGetBaseAddressOfPlane(copy, plane)!
            let fromStride = CVPixelBufferGetBytesPerRowOfPlane(frame, plane), toStride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(frame, plane) {
                memcpy(to + row * toStride, from + row * fromStride, min(fromStride, toStride))
            }
        }
        CVPixelBufferUnlockBaseAddress(copy, [])
        CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        return copy
    }

    /// A copy of `frame` with one to three rectangles of new content (of
    /// any size from a pixel to a quarter of the frame, often at an edge), or
    /// now and then all new content.
    private func changed(_ frame: CVPixelBuffer, random: inout SplitMix64) throws -> CVPixelBuffer {
        let next = try copy(frame)
        let everything = random.next() % 8 == 0
        for _ in 0..<(everything ? 1 : Int.random(in: 1...3, using: &random)) {
            let w = everything ? width : Int.random(in: 1...width / 4, using: &random)
            let h = everything ? height : Int.random(in: 1...height / 4, using: &random)
            let x = [0, width - w, Int.random(in: 0...width - w, using: &random)].randomElement(using: &random)!
            let y = [0, height - h, Int.random(in: 0...height - h, using: &random)].randomElement(using: &random)!
            let rect = PixelRect(x0: x, y0: y, x1: x + w, y1: y + h)
            // New noise, or a flat fill (a glyph, a window).
            let flat = { (random: inout SplitMix64) in random.next() % 2 == 0 ? nil : UInt8(truncatingIfNeeded: random.next()) }
            switch Int.random(in: 0..<3, using: &random) {
            case 0: edit(next, plane: 0, rect: rect, flat: flat(&random), random: &random)
            case 1: edit(next, plane: 1, rect: rect.cells(of: 2), flat: flat(&random), random: &random)
            default:
                edit(next, plane: 0, rect: rect, flat: flat(&random), random: &random)
                edit(next, plane: 1, rect: rect.cells(of: 2), flat: flat(&random), random: &random)
            }
        }
        return next
    }

    /// Sets every sample of `rect` (in the plane's own samples) to `flat`,
    /// or changes each one by a random amount.
    private func edit(_ frame: CVPixelBuffer, plane: Int, rect: PixelRect, flat: UInt8? = nil, random: inout SplitMix64) {
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let base = CVPixelBufferGetBaseAddressOfPlane(frame, plane)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(frame, plane), bytes = plane + 1
        var bits: UInt64 = 0
        for y in rect.y0..<rect.y1 {
            for i in rect.x0 * bytes..<rect.x1 * bytes {
                if let flat {
                    // Chroma pairs get two different values.
                    base[y * stride + i] = i % 2 == 0 || plane == 0 ? flat : ~flat
                    continue
                }
                if bits == 0 { bits = random.next() }
                // Never 0: every sample changes.
                base[y * stride + i] ^= UInt8(truncatingIfNeeded: bits) | 1
                bits >>= 8
            }
        }
    }
}

/// A seeded generator: the same frames on every run.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
