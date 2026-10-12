import CoreMedia
import Foundation
import JetKVMCore
import VideoToolbox

/// Hardware H.264/H.265 decoding with VideoToolbox. Decoded frames are
/// delivered as IOSurface-backed NV12 pixel buffers, ready for zero-copy
/// Metal textures.
final class VideoDecoder {
    struct Stats {
        var received = 0
        var decoded = 0
        var errors = 0
        var keyframes = 0
        var skipped = 0
        var lastDecodeMs: Double = 0
    }

    /// Called on VideoToolbox's callback thread.
    var onFrame: ((CVPixelBuffer, AccessUnitHeader) -> Void)?
    /// Asks the device for a keyframe (decoder queue). Every wait for one
    /// must ask: the patched firmware sends keyframes only on request (or
    /// once a minute), so a silent wait freezes the picture for up to that.
    var onKeyframeNeeded: (() -> Void)?

    private let queue = DispatchQueue(label: "jetkvm.decoder", qos: .userInteractive)
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var codec: AccessUnitHeader.Codec?
    private var waitingForKeyframe = true
    // Why the current wait began, and when its first unit was dropped.
    private var waitCause = "start"
    private var waitStarted: UInt64 = 0
    private var lastKeyframeRequest: UInt64 = 0
    private(set) var stats = Stats()
    private let statsLock = NSLock()
    private var pausedFlag = false

    /// While paused (window hidden) units are dropped without decoding;
    /// decoding resumes at a keyframe requested once units are wanted again.
    var paused: Bool {
        get { statsLock.lock(); defer { statsLock.unlock() }; return pausedFlag }
        set { statsLock.lock(); pausedFlag = newValue; statsLock.unlock() }
    }

    func snapshot() -> Stats {
        statsLock.lock(); defer { statsLock.unlock() }
        return stats
    }

    private var queued = 0
    /// Units allowed to wait for the decoder: one second at 60 fps. Bursts
    /// (frames released together after a repaired loss or a network hiccup)
    /// must fit: decoding takes about 1 ms a frame, so catching up is far
    /// cheaper than a keyframe. Beyond that the decoder is stuck, and skips
    /// to a requested keyframe instead of building latency.
    private let maxQueued = 60

    /// Decodes one Annex-B access unit. Safe to call from any thread.
    func decode(_ header: AccessUnitHeader, annexB: Data) {
        statsLock.lock()
        stats.received += 1
        let backlog = queued
        if backlog < maxQueued || header.keyframe { queued += 1 }
        statsLock.unlock()
        guard backlog < maxQueued || header.keyframe else {
            queue.async { self.waitForKeyframe("decoder \(backlog) units behind") }
            bump { $0.skipped += 1 }
            return
        }
        queue.async {
            self.decodeOnQueue(header, annexB: annexB)
            self.statsLock.lock()
            self.queued -= 1
            self.statsLock.unlock()
        }
    }

    func reset() {
        queue.async {
            self.invalidate()
            self.waitForKeyframe("reset")
        }
    }

    /// Drops units until a keyframe (decoder queue).
    private func waitForKeyframe(_ cause: String) {
        guard !waitingForKeyframe else { return }
        waitingForKeyframe = true
        waitCause = cause
        waitStarted = 0
    }

    /// Rate-limited to one request per 250 ms (decoder queue).
    private func requestKeyframe() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastKeyframeRequest >= 250_000_000 else { return }
        lastKeyframeRequest = now
        onKeyframeNeeded?()
    }

    private func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
        parameterSets = []
    }

    private func decodeOnQueue(_ header: AccessUnitHeader, annexB: Data) {
        if paused {
            waitForKeyframe("window hidden")
            return
        }
        let annexCodec: AnnexB.Codec = header.codec == .h265 ? .h265 : .h264
        let split = AnnexB.split(annexB, codec: annexCodec)
        if codec != header.codec {
            invalidate()
            codec = header.codec
            waitForKeyframe("codec change")
        }
        if !split.parameterSets.isEmpty && split.parameterSets != parameterSets {
            // New stream configuration (first keyframe, or a resolution change).
            invalidate()
            guard createSession(parameterSets: split.parameterSets, codec: header.codec) else {
                bump { $0.errors += 1 }
                waitForKeyframe("decoder session not created")
                requestKeyframe()
                return
            }
        }
        if waitingForKeyframe {
            let now = DispatchTime.now().uptimeNanoseconds
            guard split.isKeyframe, session != nil else {
                if waitStarted == 0 { waitStarted = now }
                requestKeyframe()
                return
            }
            waitingForKeyframe = false
            if waitStarted != 0 {
                AppLog.log(String(format: "video resumed at a keyframe after %.0f ms (%@)", Double(now - waitStarted) / 1e6, waitCause))
            }
        }
        guard let session, let format, !split.lengthPrefixed.isEmpty else { return }
        if split.isKeyframe { bump { $0.keyframes += 1 } }

        var blockBuffer: CMBlockBuffer?
        let length = split.lengthPrefixed.count
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: 0, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return }
        status = split.lengthPrefixed.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: length)
        }
        guard status == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = length
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return }

        let started = DispatchTime.now().uptimeNanoseconds
        // Synchronous decode: lowest latency, and the decoder queue already
        // keeps the caller (the pipe reader) free.
        let decodeStatus = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer else {
                // Later frames reference this one: repair with a keyframe.
                self.bump { $0.errors += 1 }
                self.requestKeyframe()
                return
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            self.bump {
                $0.decoded += 1
                $0.lastDecodeMs = ms
            }
            self.onFrame?(imageBuffer, header)
        }
        if decodeStatus != noErr {
            bump { $0.errors += 1 }
            requestKeyframe()
            if decodeStatus == kVTInvalidSessionErr {
                invalidate()
                waitForKeyframe("decoder session invalidated")
            }
        }
    }

    private func bump(_ update: (inout Stats) -> Void) {
        statsLock.lock()
        update(&stats)
        statsLock.unlock()
    }

    private func createSession(parameterSets: [Data], codec: AccessUnitHeader.Codec) -> Bool {
        var formatOut: CMVideoFormatDescription?
        let pointers = parameterSets.map { data -> UnsafePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: p, count: data.count)
            return UnsafePointer(p)
        }
        defer { pointers.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
        let sizes = parameterSets.map { $0.count }
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &formatOut)
        case .h265:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &formatOut)
        }
        guard status == noErr, let formatOut else { return false }

        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let decoderSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var sessionOut: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: formatOut,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: imageAttributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &sessionOut)
        guard created == noErr, let sessionOut else { return false }
        VTSessionSetProperty(sessionOut, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = sessionOut
        format = formatOut
        self.parameterSets = parameterSets
        return true
    }
}
