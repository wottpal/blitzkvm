import AppKit
import CoreVideo
import JetKVMCore

/// `--latency-probe N`: measures input-to-photon latency through the whole
/// app, N times, prints a JSON report and exits. Each sample presses a key on
/// the remote (HID "x") and waits for the decoded picture to change in a
/// probe region; the remote shows tools/latency-probe/latency.html, which
/// flips a large square between black and white on every key press. Times
/// are from the key's send to (1) the decoded frame that shows the change and
/// (2) the moment that frame reached the screen (MTLDrawable.presentedTime).
/// The host's own input-to-display time is part of every sample.
final class LatencyProbe {
    private weak var controller: DeviceWindowController?
    private let samples: Int
    /// Probe region in remote pixels (inside the page's square for any
    /// browser chrome height up to ~140 px).
    private let region = CGRect(x: 320, y: 500, width: 200, height: 200)
    /// The page's mid-gray marker: keys are sent only while it is on screen,
    /// so they can never reach another app on the remote.
    private let marker = CGRect(x: 1000, y: 330, width: 200, height: 200)
    private var markerSeen = false
    /// BLITZKVM_PROBE_POINTER=1: moves the pointer between two spots on the
    /// page's black area instead of pressing a key, and waits for the
    /// cursor to show at the new spot.
    private let pointerMode = ProcessInfo.processInfo.environment["BLITZKVM_PROBE_POINTER"] == "1"
    /// BLITZKVM_PROBE_WHEEL=1: a wheel tick instead of a key (the page flips
    /// its square on wheel events too).
    private let wheelMode = ProcessInfo.processInfo.environment["BLITZKVM_PROBE_WHEEL"] == "1"
    /// Pointer spots as fractions of the remote picture: on the page's black
    /// area below its marker, clear of the counter, at any size from 1280×720.
    private let targets = [CGPoint(x: 0.62, y: 0.86), CGPoint(x: 0.72, y: 0.93)]
    private var target = 0
    /// BLITZKVM_PROBE_PAIR_GAP=S: each sample first presses a key that is not
    /// measured, then the measured one S seconds later (S near 0.55 lands it
    /// on the still refresh the first change triggers).
    private let pairGap = Double(ProcessInfo.processInfo.environment["BLITZKVM_PROBE_PAIR_GAP"] ?? "")
    /// BLITZKVM_PROBE_KEYFRAME_LEAD=S: asks for a keyframe S seconds before
    /// each key, so the key's frame follows a large one (the cost of a big
    /// frame in flight, e.g. a still refresh).
    private let keyframeLead = Double(ProcessInfo.processInfo.environment["BLITZKVM_PROBE_KEYFRAME_LEAD"] ?? "")
    private var aborted: String?
    private let lock = NSLock()
    private var bright: Bool?
    private var sentAt: CFTimeInterval?
    private var expectBright = false
    private var decodedSerial: UInt64?
    private var current: (decoded: Double, presented: Double?)?
    private var results: [(decoded: Double, presented: Double)] = []
    /// Per sample, ms after the decoded frame: render start, drawable,
    /// committed, GPU done, presented.
    private var stages: [[Double]] = []
    private var currentStages: [Double]?
    /// Absolute presentedTime of every frame presented (any frame), to check
    /// whether presents land on the display's vsync grid.
    private var presentTimes: [CFTimeInterval] = []
    private var engineToDecoded: [Double] = []
    private var decodedAt: CFTimeInterval = 0
    private var misses = 0
    /// The remote picture's size, from the last decoded frame.
    private var remoteSize = CGSize(width: 1920, height: 1080)

    init(controller: DeviceWindowController, samples: Int) {
        self.controller = controller
        self.samples = samples
        controller.onFrameDecoded = { [weak self] buffer, header in
            // Engine receive -> decoded in the app (wall clock, same machine).
            let ms = (Date().timeIntervalSince1970 - Double(header.receivedUnixNano) / 1e9) * 1000
            self?.lock.lock()
            if self?.engineToDecoded.count ?? 0 < 4000 { self?.engineToDecoded.append(ms) }
            self?.lock.unlock()
            self?.frameDecoded(buffer)
        }
        controller.videoView.onPresented = { [weak self] serial, timeline in self?.presented(serial: serial, timeline) }
    }

    func start() {
        // BLITZKVM_PROBE_FULLSCREEN=1 measures in full screen.
        if ProcessInfo.processInfo.environment["BLITZKVM_PROBE_FULLSCREEN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.controller?.window?.toggleFullScreen(nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.next() }
    }

    private func next() {
        guard let controller else { return }
        lock.lock()
        if let c = current, let p = c.presented {
            results.append((c.decoded, p))
            if let st = currentStages { stages.append(st) }
        } else if sentAt != nil {
            misses += 1
        }
        current = nil
        currentStages = nil
        decodedSerial = nil
        let done = results.count + misses >= samples
        let known = bright
        if !markerSeen && known != nil {
            aborted = "probe page not on screen (marker missing); no key sent"
        }
        let stop = aborted != nil
        lock.unlock()
        if done || stop {
            finish()
            return
        }
        guard let known else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.next() }
            return
        }
        lock.lock()
        expectBright = !known
        target ^= 1
        sentAt = CACurrentMediaTime()
        lock.unlock()
        if let keyframeLead, !pointerMode {
            lock.lock()
            sentAt = nil
            lock.unlock()
            controller.engine.requestKeyframe()
            DispatchQueue.main.asyncAfter(deadline: .now() + keyframeLead) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.sentAt = CACurrentMediaTime()
                self.lock.unlock()
                controller.engine.write(EngineProtocol.key(hid: 0x1B, pressed: true))
                controller.stillRefresh.inputSent(keysHeld: false) // like typing: the refresh planner sees it
                controller.engine.write(EngineProtocol.key(hid: 0x1B, pressed: false))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + keyframeLead + 1.4) { [weak self] in self?.next() }
            return
        }
        if let pairGap, !pointerMode {
            // Unmeasured first key; the measured one follows after the gap.
            lock.lock()
            sentAt = nil
            expectBright = known
            lock.unlock()
            controller.engine.write(EngineProtocol.key(hid: 0x1B, pressed: true))
            controller.stillRefresh.inputSent(keysHeld: false) // like typing: the refresh planner sees it
            controller.engine.write(EngineProtocol.key(hid: 0x1B, pressed: false))
            DispatchQueue.main.asyncAfter(deadline: .now() + pairGap) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.sentAt = CACurrentMediaTime()
                self.lock.unlock()
                controller.engine.write(EngineProtocol.key(hid: 0x1B, pressed: true))
                controller.stillRefresh.inputSent(keysHeld: false) // like typing: the refresh planner sees it
                controller.engine.write(EngineProtocol.key(hid: 0x1B, pressed: false))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + pairGap + 1.4) { [weak self] in self?.next() }
            return
        }
        if pointerMode {
            // The device's absolute range is 0...32767 across the remote picture.
            controller.engine.write(EngineProtocol.absolutePointer(x: Int32(targets[target].x * 32767), y: Int32(targets[target].y * 32767), buttons: 0))
        } else if wheelMode {
            controller.engine.write(EngineProtocol.wheel(y: target == 0 ? 1 : -1, x: 0))
        } else {
            controller.engine.write(EngineProtocol.key(hid: 0x1B, pressed: true))
            controller.stillRefresh.inputSent(keysHeld: false) // like typing: the refresh planner sees it
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                controller.engine.write(EngineProtocol.key(hid: 0x1B, pressed: false))
            }
        }
        // Spaced so the still refresh after each change cannot overlap the
        // next sample's frames.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.next() }
    }

    private func frameDecoded(_ buffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard let level = lumaLevel(buffer, region), let mark = lumaLevel(buffer, marker) else { return }
        let isBright = level > 128
        lock.lock()
        defer { lock.unlock() }
        remoteSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        markerSeen = mark > 100 && mark < 156
        if pointerMode {
            // The arrow's white body sits just below and right of its tip.
            let p = CGPoint(x: targets[target].x * remoteSize.width, y: targets[target].y * remoteSize.height)
            let cursor = (maxLuma(buffer, CGRect(x: p.x, y: p.y, width: 14, height: 20)) ?? 0) > 150
            if let sentAt, current == nil, cursor {
                current = ((now - sentAt) * 1000, nil)
                decodedAt = now
                decodedSerial = (controller?.videoView.frameSerial ?? 0) &+ 1 // display() numbers this frame next
            }
            bright = isBright
            return
        }
        if let sentAt, current == nil, isBright == expectBright, bright != isBright {
            current = ((now - sentAt) * 1000, nil)
            decodedAt = now
            decodedSerial = (controller?.videoView.frameSerial ?? 0) &+ 1 // display() numbers this frame next
        }
        bright = isBright
    }

    private func presented(serial: UInt64, _ t: VideoView.RenderTimeline) {
        lock.lock()
        defer { lock.unlock() }
        if t.presented > 0 && presentTimes.count < 4000 { presentTimes.append(t.presented) }
        guard let sentAt, let decodedSerial, serial >= decodedSerial, let c = current, c.presented == nil, t.presented > 0 else { return }
        current = (c.decoded, (t.presented - sentAt) * 1000)
        currentStages = [t.renderStart, t.drawable, t.committed, t.gpuDone, t.presented].map { (($0 - decodedAt) * 10000).rounded() / 10 }
    }

    private func maxLuma(_ buffer: CVPixelBuffer, _ box: CGRect) -> Int? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var m = 0
        for y in Int(box.minY)..<min(h, Int(box.maxY)) {
            for x in Int(box.minX)..<min(w, Int(box.maxX)) { m = max(m, Int(p[y * stride + x])) }
        }
        return m
    }

    /// Mean luma of a sparse grid in the probe region (video range).
    private func lumaLevel(_ buffer: CVPixelBuffer, _ region: CGRect) -> Double? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, n = 0
        for gy in 0..<5 {
            for gx in 0..<5 {
                let x = Int(region.minX) + gx * Int(region.width) / 4, y = Int(region.minY) + gy * Int(region.height) / 4
                guard x < w, y < h else { continue }
                sum += Int(p[y * stride + x])
                n += 1
            }
        }
        return n > 0 ? Double(sum) / Double(n) : nil
    }

    private func finish() {
        lock.lock()
        let r = results, missed = misses, abortReason = aborted, st = stages, pt = presentTimes, ed = engineToDecoded
        lock.unlock()
        func stats(_ v: [Double]) -> [String: Double] {
            let s = v.sorted()
            guard !s.isEmpty else { return [:] }
            func q(_ f: Double) -> Double { (s[min(s.count - 1, Int(f * Double(s.count)))] * 100).rounded() / 100 }
            return ["median": q(0.5), "p10": q(0.1), "p90": q(0.9), "min": q(0), "max": q(1),
                    "mean": ((s.reduce(0, +) / Double(s.count)) * 100).rounded() / 100]
        }
        let report: [String: Any] = [
            "samples": r.count, "misses": missed, "aborted": abortReason ?? "",
            "decoded_ms": stats(r.map(\.decoded)),
            "presented_ms": stats(r.map(\.presented)),
            "decode_to_present_ms": stats(r.map { $0.presented - $0.decoded }),
            "engine_to_decoded_ms": stats(ed),
            "present_times": pt.map { ($0 * 1_000_000).rounded() / 1_000_000 },
            "raw": r.map { [($0.decoded * 10).rounded() / 10, ($0.presented * 10).rounded() / 10] },
            "stages_after_decode_ms": ["render_start", "drawable", "committed", "gpu_done", "presented"].enumerated().reduce(into: [String: Any]()) { acc, e in
                acc[e.element] = stats(st.map { $0[e.offset] })
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        fflush(stdout)
        controller?.shutdown()
        exit(0)
    }
}
