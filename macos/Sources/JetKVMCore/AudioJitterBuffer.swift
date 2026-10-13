import Foundation

/// G.711 µ-law, the codec of stock firmware's audio (PCMU).
public enum MuLaw {
    /// Each code's sample, scaled to -1...1.
    public static let table: [Float] = (0...255).map { Float(linear(UInt8($0))) / 32768 }

    /// The G.711 decoder.
    public static func linear(_ code: UInt8) -> Int16 {
        let u = ~code
        let magnitude = ((Int(u & 0x0f) << 3) + 0x84) << Int((u >> 4) & 7)
        return Int16(u & 0x80 != 0 ? 0x84 - magnitude : magnitude - 0x84)
    }
}

/// Between the network and the audio output, for the device's audio as
/// 48 kHz stereo (interleaved in, planar out). Times are seconds on one
/// monotonic clock.
///
/// A packet's slack is how long before its first frame must be pulled for
/// the output it arrived. Each talkspurt (sound after silence) is anchored
/// anew: its first packet plays with `targetSlack`, whatever timing the one
/// before had. A packet that continues a stream that ran dry (the device
/// stalled, then sent what it held at once) plays with `margin`, and what
/// came with it keeps the latency up by the stall, so the next stall of
/// that size passes without a gap. The spread of the slack over the last
/// 20 s sets `targetSlack`: jitter and stalls raise it, and it falls again
/// 20 s after they end. While the lowest slack of the last 20 s exceeds
/// `margin`, the latency is cut a little each second by skipping a few
/// milliseconds with a crossfade; a packet that came closer gets them back
/// by a repeat. Both also absorb the drift between the device's clock and
/// the Mac's. Sound fades in where it starts and out where it stops.
public struct AudioJitterBuffer {
    public static let sampleRate = 48_000.0

    public struct Stats: Equatable {
        /// Sound started after silence.
        public var starts = 0
        /// The stream ran dry and then went on: packets came late.
        public var stalls = 0
        /// Ran dry while playing: the sound ended, or a stall.
        public var underruns = 0
        /// Frames played from the queue: sound, and silence that separates
        /// talkspurts in it.
        public var playedFrames = 0
        /// Frames skipped to cut latency, and repeated to add it.
        public var skippedFrames = 0
        public var repeatedFrames = 0
        /// Frames dropped because the output stopped taking them.
        public var overflowFrames = 0

        public init() {}
    }

    /// The least slack the latest packet should have.
    public let margin: Double
    public let maximumSlack: Double
    /// The slack sound starts with after silence.
    public private(set) var targetSlack: Double
    public private(set) var stats = Stats()

    /// The latency sound starts with after silence (arrival to output).
    public var target: Double { targetSlack + structural }

    // Deviation from the margin left alone, the most latency changed per
    // window, the window, how many windows count, and the longest stall
    // after which a stream goes on (longer: it starts anew).
    private let tolerance = 0.01
    private let maxCorrection = 0.05
    private let window = 1.0
    private let windows = 20
    private let maxStall = 1.0
    /// Crossfades and fades, in frames (5 ms).
    private let fade = 240

    private var ring: [Float]
    private let capacity: Int
    /// Absolute frame positions: the next frame to play and to write.
    private var readPos = 0
    private var writePos = 0
    private enum State: Equatable { case idle, waiting(until: Double), playing }
    private var state = State.idle
    /// Where the current stream began (repeats stay within it).
    private var streamStart = 0
    /// The fade-out after running dry: frames still to play, its length,
    /// and where the sound ended.
    private var fadeOut = 0
    private var fadeLength = 0
    private var fadeEnd = 0
    /// When the stream ran dry (output time).
    private var dryAt: Double?
    /// Output time of the frame at readPos, as of the last pull.
    private var next: Double?
    /// From a pull to the output of its last frame: the output's latency
    /// and one buffer (a guess until the first pull).
    private var structural = 0.025
    /// Latency to change, in frames: positive skips, negative repeats.
    private var correction = 0
    /// Slack: lowest and highest of the current window, since windowStart,
    /// and of the windows before.
    private var windowStart: Double?
    private var low = Double.infinity
    private var high = -Double.infinity
    private var history: [(low: Double, high: Double)] = []
    /// Arrival of each packet's first frame, to measure delays.
    private var marks: [(position: Int, arrival: Double)]
    private var markHead = 0
    private var markCount = 0
    /// Recently measured delays (arrival to output), a ring.
    private var delays: [Double]
    private var delayCount = 0

    public init(margin: Double = 0.015, maximumSlack: Double = 1, capacity: Double = 2) {
        self.margin = margin
        self.maximumSlack = maximumSlack
        targetSlack = margin
        self.capacity = Int(capacity * Self.sampleRate)
        ring = [Float](repeating: 0, count: self.capacity * 2)
        marks = Array(repeating: (0, 0), count: 256)
        delays = Array(repeating: 0, count: 512)
        history.reserveCapacity(windows + 1)
    }

    /// Frames waiting to play.
    public var buffered: Int { writePos - readPos }
    /// Output time of the frame at readPos (nil: nothing plays).
    private var head: Double? {
        switch state {
        case .idle: nil
        case .waiting(let until): until
        case .playing: next
        }
    }
    /// Nothing plays (silence until the next packet).
    public var isIdle: Bool { state == .idle && fadeOut == 0 }

    /// Appends one packet's frames (interleaved stereo). `starts`: it
    /// begins a talkspurt (the first packet after silence).
    public mutating func push(_ samples: UnsafeBufferPointer<Float>, arrival: Double, starts: Bool) {
        let frames = samples.count / 2
        guard frames > 0 else { return }
        var slack: Double?
        if starts || state == .idle {
            // A new window: what came after a stall measures it on its own.
            closeWindow()
            if !starts, let dryAt, arrival - dryAt < maxStall {
                stats.stalls += 1
                slack = margin
            } else {
                // Stock firmware marks no talkspurts: sound after a second
                // of silence starts one too.
                stats.starts += 1
                slack = targetSlack
            }
            anchor(at: arrival + slack! + structural)
        } else if next != nil, let head {
            note(head + Double(buffered) / Self.sampleRate - structural - arrival, at: arrival)
        }
        if buffered + frames > capacity {
            let overflow = buffered + frames - capacity
            readPos += overflow
            stats.overflowFrames += overflow
            measure(through: readPos, offset: nil, at: 0)
        }
        marks[(markHead + markCount) % marks.count] = (writePos, arrival)
        if markCount < marks.count { markCount += 1 } else { markHead = (markHead + 1) % marks.count }
        for i in 0..<frames {
            let at = (writePos + i) % capacity * 2
            let gain: Float = slack != nil && i < fade ? Float(i) / Float(fade) : 1 // fade in
            ring[at] = samples[2 * i] * gain
            ring[at + 1] = samples[2 * i + 1] * gain
        }
        writePos += frames
        // Slack is only known while the output runs (it may still be
        // starting: then this packet plays late, and the latency is cut).
        if let slack, next != nil { note(slack, at: arrival) }
    }

    /// Writes `count` frames, pulled at `now`, whose first reaches the
    /// output at `time`.
    public mutating func pull(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int, at time: Double, now: Double) {
        structural = time - now + Double(count) / Self.sampleRate
        next = time + Double(count) / Self.sampleRate
        left.update(repeating: 0, count: count)
        right.update(repeating: 0, count: count)
        var done = 0
        if fadeOut > 0 {
            done = decay(left: left, right: right, count: count)
        }
        if case .waiting(let until) = state {
            done = max(done, min(count, Int(((until - time) * Self.sampleRate).rounded())))
            guard done < count else { return }
            state = .playing
        }
        guard state == .playing else { return }
        if correction != 0, count - done >= fade {
            done += jump(left: left + done, right: right + done)
        }
        let n = min(count - done, buffered)
        for i in 0..<n {
            let at = (readPos + i) % capacity * 2
            left[done + i] = ring[at]
            right[done + i] = ring[at + 1]
        }
        measure(through: readPos + n, offset: done - readPos, at: time)
        readPos += n
        stats.playedFrames += n
        done += n
        if done < count {
            // Ran dry: the sound goes on backwards, fading out (no click).
            state = .idle
            dryAt = time + Double(done) / Self.sampleRate
            correction = 0
            markCount = 0
            stats.underruns += 1
            fadeEnd = readPos
            fadeLength = min(fade, readPos - streamStart)
            fadeOut = fadeLength
            _ = decay(left: left + done, right: right + done, count: count - done)
        }
    }

    /// Forgets what is buffered, keeping what was learned about the link
    /// (the output stopped).
    public mutating func reset() {
        readPos = writePos
        state = .idle
        next = nil
        dryAt = nil
        correction = 0
        markCount = 0
        fadeOut = 0
        closeWindow()
    }

    /// Arrival-to-output delays measured recently, sorted (seconds).
    public func recentDelays() -> [Double] {
        Array(delays.prefix(min(delayCount, delays.count))).sorted()
    }

    /// Makes the next packet play at output time `time`: after silence,
    /// or after what is queued, cut (faded out) or padded with silence to
    /// end there.
    private mutating func anchor(at time: Double) {
        defer {
            streamStart = writePos
            correction = 0
        }
        guard let head else {
            readPos = writePos
            state = .waiting(until: time)
            return
        }
        let pad = Int(((time - head) * Self.sampleRate).rounded()) - buffered
        if pad < 0 {
            writePos = readPos + max(0, buffered + pad)
            while markCount > 0, marks[(markHead + markCount - 1) % marks.count].position >= writePos { markCount -= 1 }
        }
        let tail = min(fade, buffered)
        for i in 0..<tail {
            let at = (writePos - tail + i) % capacity * 2
            let gain = Float(tail - i) / Float(tail + 1)
            ring[at] *= gain
            ring[at + 1] *= gain
        }
        for i in 0..<min(max(pad, 0), capacity - buffered) {
            let at = (writePos + i) % capacity * 2
            ring[at] = 0
            ring[at + 1] = 0
        }
        writePos += min(max(pad, 0), capacity - buffered)
    }

    /// Plays the fade-out after running dry: the last frames, backwards.
    /// Returns how many frames it wrote.
    private mutating func decay(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let n = min(fadeOut, count)
        for i in 0..<n {
            let k = fadeLength - fadeOut + i // frames into the fade-out
            let at = (fadeEnd - 1 - k) % capacity * 2
            let gain = Float(fadeLength - k) / Float(fadeLength + 1)
            left[i] = ring[at] * gain
            right[i] = ring[at + 1] * gain
        }
        fadeOut -= n
        return n
    }

    /// Notes a packet's slack; once a window is full, updates the target
    /// and plans a correction.
    private mutating func note(_ slack: Double, at time: Double) {
        if windowStart == nil { windowStart = time }
        low = min(low, slack)
        high = max(high, slack)
        guard let start = windowStart, time - start >= window else { return }
        closeWindow()
        guard state != .idle, let lowest = history.lazy.map(\.low).min(), let last = history.last?.low else { return }
        if lowest > margin + tolerance {
            correction = Int((min(lowest - margin, maxCorrection) * Self.sampleRate).rounded())
        } else if last < margin - tolerance {
            correction = -Int((min(margin - last, maxCorrection) * Self.sampleRate).rounded())
        }
    }

    private mutating func closeWindow() {
        windowStart = nil
        guard low <= high else { return }
        history.append((low, high))
        if history.count > windows { history.removeFirst() }
        low = .infinity
        high = -.infinity
        let spread = history.lazy.map { $0.high - $0.low }.max() ?? 0
        targetSlack = min(margin + spread, maximumSlack)
    }

    /// Applies the planned correction at the read position: crossfades
    /// from what plays now into what plays `correction` frames later (a
    /// skip) or earlier (a repeat). Writes `fade` frames and returns how
    /// many it wrote (0 while it cannot apply yet).
    private mutating func jump(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Int {
        var offset = correction
        if offset > 0 {
            guard buffered >= offset + fade else { return 0 } // wait for more
        } else {
            // Repeat only this stream's sound that the ring still holds.
            offset = -min(-offset, readPos - streamStart, capacity - buffered - fade)
            guard buffered >= fade, -offset >= fade else {
                correction = 0
                return 0
            }
        }
        for i in 0..<fade {
            let a = (readPos + i) % capacity * 2
            let b = (readPos + offset + i) % capacity * 2
            let w = Float(i + 1) / Float(fade + 1)
            left[i] = ring[a] * (1 - w) + ring[b] * w
            right[i] = ring[a + 1] * (1 - w) + ring[b + 1] * w
        }
        if offset > 0 {
            stats.skippedFrames += offset
            measure(through: readPos + offset, offset: nil, at: 0) // skipped: not measured
        } else {
            stats.repeatedFrames -= offset
        }
        readPos += offset + fade
        stats.playedFrames += fade
        // Every slack noted so far shifts with the latency.
        let shift = -Double(offset) / Self.sampleRate
        low += shift
        high += shift
        for i in history.indices {
            history[i].low += shift
            history[i].high += shift
        }
        correction = 0
        return fade
    }

    /// Takes the marks of packets whose first frame is before `end`; each
    /// is output at `time` + (position + offset) frames (nil: not played).
    private mutating func measure(through end: Int, offset: Int?, at time: Double) {
        while markCount > 0, marks[markHead].position < end {
            if let offset {
                let delay = time + Double(marks[markHead].position + offset) / Self.sampleRate - marks[markHead].arrival
                delays[delayCount % delays.count] = delay
                delayCount += 1
            }
            markHead = (markHead + 1) % marks.count
            markCount -= 1
        }
    }
}
