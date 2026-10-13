import Foundation

/// Client-driven still refresh (fork firmware D13): when to ask the JetKVM
/// to re-encode what changed, near-losslessly, once the picture stands still.
///
/// The encoder never refines a still picture with P-frames (plan §23 R1):
/// what was encoded while it changed keeps that quality. Left to itself, the
/// fork firmware refreshes the whole frame as a keyframe at stillQp (250–350
/// KB) half a second after every change, so every typing pause sends one, and
/// a keystroke right behind it waits on the device (+23 to +61 ms). The app
/// knows what changed (each frame's changed rectangle) and when the user
/// types, so with the device's own refresh off it asks for:
/// - region refreshes after short pauses: only the regions that changed, as
///   intra blocks in P-frames (an 880×224 text area: 41.5 KB, 44.3 → 49.3
///   dB). The device clamps their QP to the P-frame floor, minQp.
/// - a full refresh after a long pause, on LAN-like links: the whole frame as
///   a keyframe at stillQp (about 60 dB at QP 1), when anything changed or was
///   region-refreshed since the last one. Slow links get region refreshes
///   only; changes too large for a short pause wait for a long one there.
///
/// A change counts when it is large or follows local input (typing, the
/// pointer); a small one on its own (a blinking caret, a clock) neither needs
/// a refresh nor keeps the picture from standing still. What a refresh itself
/// changes (its intra blocks, its keyframe) is recognized and ignored.
///
/// A pure value: callers pass times (seconds on one monotonic clock), frames,
/// input and the level, and ask `decide(at:)` what to send.
public struct RefreshPlanner {
    /// The policy's constants (seconds, pixels).
    public struct Tuning: Equatable {
        /// A short pause: the picture still this long (a typed glyph arrives
        /// in one frame and settles in a frame or two) ...
        public var regionStill: TimeInterval = 0.25
        /// ... and no input this long: longer than the gaps of steady typing,
        /// so a burst gets one refresh rather than one per key.
        public var regionInputIdle: TimeInterval = 0.4
        /// A long pause: no input for 3 s and the picture still for 1 s.
        /// Only then is the next keystroke unlikely to queue behind a full
        /// refresh's keyframe.
        public var fullInputIdle: TimeInterval = 3
        public var fullStill: TimeInterval = 1
        /// Regions above this share of the frame cost about as much as a
        /// keyframe (intra at minQp, `frames` times): they wait for a long
        /// pause.
        public var maxRegionShare = 0.35
        /// refreshRegions takes up to 6 rects; the encoder's blocks are 16 px.
        public var maxRects = 6
        public var alignment = 16
        /// Frames the regions stay intra (the device's default).
        public var frames = 2
        /// A change below this many pixels that does not follow input is
        /// minor: a blinking caret (4×40 px on a Retina target), a clock
        /// digit, a spinner.
        public var minorArea = 1024
        /// Changes this soon after input are its echo, whatever their size
        /// (key to screen takes 70–140 ms on a LAN, longer on slow links).
        public var inputEcho: TimeInterval = 1
        /// How long after a region refresh (plus the round trip) its intra
        /// blocks may still arrive, and how long a full refresh's keyframe
        /// keeps settling.
        public var refreshEcho: TimeInterval = 1
        /// How long a full refresh's keyframe may take (plus the round trip).
        public var fullAck: TimeInterval = 2
        /// Refreshes at least this far apart (bounds a runaway).
        public var minGap: TimeInterval = 0.5

        public init() {}
    }

    /// One refreshRegions call. Without rects it refreshes the whole frame
    /// (a keyframe at qp); otherwise the rects are re-encoded intra for
    /// `frames` frames at qp, which the device clamps to minQp.
    public struct Refresh: Equatable {
        public var rects: [PixelRect]
        public var qp: Int
        public var frames: Int

        public init(rects: [PixelRect], qp: Int, frames: Int) {
            self.rects = rects
            self.qp = qp
            self.frames = frames
        }

        public var isFull: Bool { rects.isEmpty }

        /// The RPC's parameters: {"rects": [{"x", "y", "w", "h"}], "qp", "frames"}.
        public var params: JSONValue {
            func number(_ value: Int) -> JSONValue { .number(Double(value)) }
            return .object([
                "rects": .array(rects.map { .object(["x": number($0.x0), "y": number($0.y0), "w": number($0.width), "h": number($0.height)]) }),
                "qp": number(qp),
                "frames": number(frames),
            ])
        }
    }

    /// Whether full refreshes suit a link (engine stats Path, RoundTripMs):
    /// the LAN, the emulator on this Mac, or a path as fast as a LAN (the
    /// quality governor starts at its top level below the same 8 ms).
    public static func isLANLike(path: String?, rttMs: Double) -> Bool {
        path == "lan" || path == "loopback" || (rttMs > 0 && rttMs < 8)
    }

    public var tuning: Tuning
    /// The level's P-frame QP floor and still refresh QP (0: unknown).
    /// Refreshes are off unless 0 < stillQp < minQp: the lowest level turns
    /// the still refresh off that way.
    public var minQp = 0
    public var stillQp = 0
    /// A LAN-like link (isLANLike): full refreshes are allowed.
    public var lan = true
    /// The round trip (seconds): a refresh's effects arrive this much later.
    public var rtt: TimeInterval = 0

    private struct Echo {
        /// Where the refresh changes the picture.
        var area: PixelRect
        var issued: TimeInterval
        var until: TimeInterval
        /// A full refresh whose keyframe is still to come.
        var awaitsKeyframe: Bool
    }

    private var frame = PixelRect.empty
    /// Changes since the last refresh: aligned and disjoint.
    private var dirty: [PixelRect] = []
    /// Changes too large for a short pause, for the next long one.
    private var deferred: [PixelRect] = []
    /// Something changed or was region-refreshed since the last full refresh.
    private var fullDirty = false
    private var lastChange = -TimeInterval.infinity
    private var lastInput = -TimeInterval.infinity
    private var inputHeld = false
    private var lastRefresh = -TimeInterval.infinity
    private var echo: Echo?

    /// Rects kept per list before the closest are merged (bounds the work
    /// per frame).
    static let trackedRects = 32

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// Planning starts (refreshes were the device's until now): the
    /// picture's quality is unknown, so all of it waits for a long pause.
    public mutating func start(at time: TimeInterval) {
        resetPicture(at: time)
        lastRefresh = -.infinity
    }

    private mutating func resetPicture(at time: TimeInterval) {
        dirty = []
        deferred = frame.isEmpty ? [] : [frame]
        fullDirty = true
        lastChange = time
        echo = nil
    }

    /// Local input went to the remote. `held`: keys stay down or a paste is
    /// being typed, so the remote keeps changing until the next call.
    public mutating func input(at time: TimeInterval, held: Bool = false) {
        lastInput = time
        inputHeld = held
    }

    /// A frame was shown: `changed` is where it differs from the one before
    /// (empty: the same picture).
    public mutating func frame(at time: TimeInterval, width: Int, height: Int, changed: PixelRect, keyframe: Bool) {
        let whole = PixelRect(width: width, height: height)
        guard whole == frame else {
            frame = whole
            resetPicture(at: time)
            return
        }
        if let e = echo, time > e.until { echo = nil }
        if keyframe, echo?.awaitsKeyframe == true {
            // The full refresh; the frames after it may still settle.
            echo?.awaitsKeyframe = false
            echo?.until = time + tuning.refreshEcho
            return
        }
        // Any other keyframe (session start, loss repair) re-encodes it all.
        let change = keyframe ? frame : changed.intersection(frame)
        guard !change.isEmpty else { return }
        if !keyframe, let e = echo, !inputHeld, lastInput < e.issued, e.area.contains(change) { return }
        let followsInput = inputHeld || time - lastInput < tuning.inputEcho
        if !keyframe && !followsInput && change.area < tuning.minorArea { return }
        Self.add(aligned(change), to: &dirty)
        fullDirty = true
        lastChange = time
    }

    /// The refresh to send now, if any; a returned refresh counts as sent.
    public mutating func decide(at time: TimeInterval) -> Refresh? {
        guard stillQp > 0, stillQp < minQp, !frame.isEmpty, time - lastRefresh >= tuning.minGap else { return nil }
        if let e = echo, e.awaitsKeyframe, time <= e.until { return nil }
        let still = time - lastChange
        let idle = inputHeld ? 0 : time - lastInput
        if still >= tuning.fullStill && idle >= tuning.fullInputIdle {
            if lan && fullDirty { return refresh([], at: time) }
            if !lan && !(dirty.isEmpty && deferred.isEmpty) {
                var all = deferred
                dirty.forEach { Self.add($0, to: &all) }
                deferred = []
                return refresh(merged(all), at: time)
            }
        }
        guard still >= tuning.regionStill, idle >= tuning.regionInputIdle, !dirty.isEmpty else { return nil }
        let rects = merged(dirty)
        guard Double(rects.reduce(0) { $0 + $1.area }) <= tuning.maxRegionShare * Double(frame.area) else {
            dirty.forEach { Self.add($0, to: &deferred) }
            dirty = []
            return nil
        }
        return refresh(rects, at: time)
    }

    private mutating func refresh(_ rects: [PixelRect], at time: TimeInterval) -> Refresh {
        let full = rects.isEmpty
        dirty = []
        if full { deferred = [] }
        fullDirty = !full
        lastRefresh = time
        let area = full ? frame : rects.reduce(PixelRect.empty) { $0.union($1) }.outset(by: tuning.alignment).intersection(frame)
        echo = Echo(area: area, issued: time, until: time + (full ? tuning.fullAck : tuning.refreshEcho) + rtt, awaitsKeyframe: full)
        return Refresh(rects: rects, qp: stillQp, frames: tuning.frames)
    }

    /// `rect` grown outward to whole blocks, within the frame.
    private func aligned(_ rect: PixelRect) -> PixelRect {
        let a = tuning.alignment, cells = rect.cells(of: a)
        return PixelRect(x0: cells.x0 * a, y0: cells.y0 * a, x1: cells.x1 * a, y1: cells.y1 * a).intersection(frame)
    }

    /// `rects` merged down to the most one call takes.
    private func merged(_ rects: [PixelRect]) -> [PixelRect] {
        var rects = rects
        while rects.count > tuning.maxRects { Self.mergeClosest(&rects) }
        return rects
    }

    /// Adds `rect` to disjoint `rects`, merged with each it overlaps or
    /// extends into a rectangle without extra pixels (the next block of a
    /// typed line).
    static func add(_ rect: PixelRect, to rects: inout [PixelRect]) {
        var rect = rect
        while let i = rects.firstIndex(where: { !$0.intersection(rect).isEmpty || $0.union(rect).area == $0.area + rect.area }) {
            rect = rect.union(rects.remove(at: i))
        }
        rects.append(rect)
        while rects.count > trackedRects { mergeClosest(&rects) }
    }

    /// Merges the two rects whose bounding box adds the fewest pixels.
    static func mergeClosest(_ rects: inout [PixelRect]) {
        guard rects.count > 1 else { return }
        var best = (i: 0, j: 1, cost: Int.max)
        for i in rects.indices {
            for j in rects.indices where j > i {
                let cost = rects[i].union(rects[j]).area - rects[i].area - rects[j].area
                if cost < best.cost { best = (i, j, cost) }
            }
        }
        let union = rects[best.i].union(rects[best.j])
        rects.remove(at: best.j)
        rects.remove(at: best.i)
        add(union, to: &rects)
    }
}
