import XCTest
@testable import JetKVMCore

/// Timelines in, refreshes out: frames at 60 fps on a 1920×1080 picture.
final class RefreshPlannerTests: XCTestCase {
    private enum Event {
        case input(TimeInterval, held: Bool = false)
        case change(TimeInterval, PixelRect)
        case keyframe(TimeInterval)
    }

    private typealias Sent = (at: TimeInterval, refresh: RefreshPlanner.Refresh)

    /// The maximum level (minQp 10, stillQp 1), planning from t = 0.
    private func planner(lan: Bool = true) -> RefreshPlanner {
        var p = RefreshPlanner()
        p.minQp = 10
        p.stillQp = 1
        p.lan = lan
        p.start(at: 0)
        return p
    }

    /// Runs frames from `start` to `end`: each takes the input before it and
    /// the changes since the last frame, then asks for a decision. The
    /// device answers a full refresh with a keyframe 0.1 s later.
    private func run(_ p: inout RefreshPlanner, _ events: [Event], from start: TimeInterval = 0, to end: TimeInterval,
                     width: Int = 1920, height: Int = 1080) -> [Sent] {
        var pending = events
        var sent: [Sent] = []
        let step = 1.0 / 60
        for i in 0...Int(((end - start) / step).rounded()) {
            let t = start + Double(i) * step
            var changed = PixelRect.empty
            var keyframe = false
            pending.removeAll { event in
                switch event {
                case .input(let at, let held) where at <= t: p.input(at: at, held: held)
                case .change(let at, let rect) where at <= t: changed = changed.union(rect)
                case .keyframe(let at) where at <= t: keyframe = true
                default: return false
                }
                return true
            }
            p.frame(at: t, width: width, height: height, changed: changed, keyframe: keyframe)
            if let refresh = p.decide(at: t) {
                sent.append((t, refresh))
                if refresh.isFull { pending.append(.keyframe(t + 0.1)) }
            }
        }
        return sent
    }

    /// Typing: each key at `start + i * gap` shows a glyph 80 ms later, on
    /// one line from (x, y).
    private func typing(_ keys: Int, at start: TimeInterval, gap: TimeInterval = 0.15, x: Int = 100, y: Int = 200) -> [Event] {
        (0..<keys).flatMap { i -> [Event] in
            let t = start + Double(i) * gap
            return [.input(t), .change(t + 0.08, PixelRect(x0: x + i * 10, y0: y, x1: x + i * 10 + 8, y1: y + 16))]
        }
    }

    private func assertNear(_ t: TimeInterval?, _ expected: TimeInterval, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let t else { return XCTFail("\(message): none", file: file, line: line) }
        XCTAssertEqual(t, expected, accuracy: 1.0 / 60 + 1e-9, message, file: file, line: line)
    }

    func testOnALANTypingPausesRefreshRegionsAndALongPauseTheWholeFrame() {
        var p = planner()
        let sent = run(&p, typing(3, at: 5), to: 20)
        XCTAssertEqual(sent.count, 3, "\(sent)")
        // At the start the picture's quality is unknown: a full refresh as
        // soon as it has been still for a second.
        assertNear(sent.first?.at, 1, "first full refresh")
        XCTAssertEqual(sent.first?.refresh, RefreshPlanner.Refresh(rects: [], qp: 1, frames: 2))
        // The burst: one region refresh 0.4 s after the last key, the typed
        // line aligned to 16 px blocks, at stillQp (the device clamps it).
        assertNear(sent[1].at, 5.3 + 0.4, "region refresh")
        XCTAssertEqual(sent[1].refresh, RefreshPlanner.Refresh(rects: [PixelRect(x0: 96, y0: 192, x1: 128, y1: 224)], qp: 1, frames: 2))
        // 3 s after the last key: the whole frame, near-losslessly.
        assertNear(sent[2].at, 5.3 + 3, "full refresh after the long pause")
        XCTAssertTrue(sent[2].refresh.isFull)
    }

    func testNothingWhileTypingSteadily() {
        var p = planner()
        // 30 keys 0.3 s apart: never 0.4 s without input.
        let sent = run(&p, typing(30, at: 2, gap: 0.3, y: 100), to: 10.7)
        XCTAssertEqual(sent.map(\.refresh.isFull), [true], "\(sent)")
        XCTAssertEqual(sent.first?.at ?? 0, 1, accuracy: 0.02)
    }

    func testSlowLinksGetRegionRefreshesOnly() {
        var p = planner(lan: false)
        let sent = run(&p, typing(3, at: 5), to: 20)
        // The unknown start waits for a long pause, then goes as a region.
        XCTAssertEqual(sent.map(\.refresh.isFull), [false, false], "\(sent)")
        assertNear(sent.first?.at, 1, "start")
        XCTAssertEqual(sent.first?.refresh.rects, [PixelRect(width: 1920, height: 1080)])
        assertNear(sent[1].at, 5.7, "typing pause")
        XCTAssertEqual(sent[1].refresh.rects, [PixelRect(x0: 96, y0: 192, x1: 128, y1: 224)])
    }

    func testLargeChangesWaitForALongPauseWhileTypingStillGetsRegions() {
        for lan in [true, false] {
            var p = planner(lan: lan)
            // A click switches windows (46% of the frame), then a few keys.
            let events: [Event] = [.input(2), .change(2.1, PixelRect(x0: 0, y0: 0, x1: 1200, y1: 800))] + typing(2, at: 3, y: 900)
            let sent = run(&p, events, from: 0, to: 9)
            XCTAssertEqual(sent.count, 3, "lan \(lan): \(sent)")
            guard sent.count == 3 else { continue }
            assertNear(sent[1].at, 3.55, "lan \(lan): the typed line, not the window")
            XCTAssertEqual(sent[1].refresh.rects, [PixelRect(x0: 96, y0: 896, x1: 128, y1: 928)])
            assertNear(sent[2].at, 6.15, "lan \(lan): the window at the long pause")
            if lan {
                XCTAssertTrue(sent[2].refresh.isFull)
            } else {
                XCTAssertEqual(sent[2].refresh.rects, [PixelRect(x0: 0, y0: 0, x1: 1200, y1: 800)])
            }
        }
    }

    func testABlinkingCaretNeitherRefreshesNorBlocksTheLongPause() {
        var p = planner()
        // After a burst the caret blinks every 0.53 s, without input.
        let caret = PixelRect(x0: 130, y0: 198, x1: 132, y1: 218)
        let blinks = (0..<20).map { Event.change(5.6 + Double($0) * 0.53, caret) }
        let sent = run(&p, typing(3, at: 5) + blinks, from: 0, to: 15)
        XCTAssertEqual(sent.map(\.refresh.isFull), [true, false, true], "\(sent)")
        assertNear(sent.last?.at, 8.3, "full refresh despite the caret")

        // Alone, it never asks for anything.
        var idle = planner()
        let quiet = run(&idle, (0..<30).map { Event.change(2 + Double($0) * 0.53, caret) }, to: 18)
        XCTAssertEqual(quiet.count, 1, "only the start: \(quiet)")
    }

    func testLargeChangesWithoutInputCount() {
        var p = planner()
        // Output appears in a terminal without input (a build log).
        let output = (0..<5).map { Event.change(3 + Double($0) * 0.1, PixelRect(x0: 0, y0: 500 + $0 * 20, x1: 800, y1: 520 + $0 * 20)) }
        let sent = run(&p, output, to: 5)
        XCTAssertEqual(sent.map(\.refresh.isFull), [true, false, true], "\(sent)")
        guard sent.count == 3 else { return }
        assertNear(sent[1].at, 3.4 + 0.25, "still for 250 ms")
        XCTAssertEqual(sent[1].refresh.rects, [PixelRect(x0: 0, y0: 496, x1: 800, y1: 608)])
        // Nobody is typing: the long pause is a second of stillness.
        assertNear(sent[2].at, 3.4 + 1, "full refresh")
    }

    func testARefreshIgnoresItsOwnChanges() {
        var p = planner()
        // The region refresh at 5.7 re-encodes the typed line: its frames
        // differ there (twice), which must not ask for it again. The full
        // refresh's keyframe and the frames settling after it are its own.
        let line = PixelRect(x0: 100, y0: 200, x1: 128, y1: 216)
        let events = typing(3, at: 5) + [.change(5.8, line), .change(5.82, line), .change(8.45, PixelRect(width: 1920, height: 1080))]
        let sent = run(&p, events, to: 20)
        XCTAssertEqual(sent.map(\.refresh.isFull), [true, false, true], "\(sent)")
    }

    func testChangesElsewhereDuringAnEchoStillCount() {
        var p = planner()
        let events = typing(3, at: 5) + [.change(5.8, PixelRect(x0: 1000, y0: 600, x1: 1300, y1: 700))]
        let sent = run(&p, events, to: 7)
        XCTAssertEqual(sent.count, 3, "\(sent)")
        assertNear(sent.last?.at, 6.2, "0.5 s after the last refresh")
        XCTAssertEqual(sent.last?.refresh.rects, [PixelRect(x0: 992, y0: 592, x1: 1312, y1: 704)])
    }

    func testAKeyframeNobodyAskedForReencodesEverything() {
        var p = planner()
        // Loss repair: a keyframe at 10 s, long after the start's refresh.
        let sent = run(&p, [.keyframe(10)], to: 12)
        XCTAssertEqual(sent.map(\.refresh.isFull), [true, true], "\(sent)")
        assertNear(sent.last?.at, 11, "still for a second after it")
    }

    func testHeldInputDefersRefreshes() {
        var p = planner()
        // A paste types for 3 s without local input events.
        var events: [Event] = [.input(2, held: true), .input(5, held: false)]
        events += (0..<30).map { .change(2.1 + Double($0) * 0.1, PixelRect(x0: 100 + $0 * 10, y0: 300, x1: 108 + $0 * 10, y1: 316)) }
        let sent = run(&p, events, to: 9)
        XCTAssertEqual(sent.map(\.refresh.isFull), [true, false, true], "\(sent)")
        assertNear(sent[1].at, 5.4, "after the paste")
        XCTAssertEqual(sent[1].refresh.rects, [PixelRect(x0: 96, y0: 288, x1: 400, y1: 320)])
        assertNear(sent[2].at, 8, "long pause")
    }

    func testLevelsWithoutAStillRefreshNeverRefresh() {
        for (minQp, stillQp) in [(26, 26), (18, 0), (0, 0)] {
            var p = planner()
            p.minQp = minQp
            p.stillQp = stillQp
            XCTAssertTrue(run(&p, typing(3, at: 2), to: 10).isEmpty, "minQp \(minQp) stillQp \(stillQp)")
        }
    }

    func testANewSizeStartsOver() {
        var p = planner()
        _ = run(&p, [], to: 3)
        let sent = run(&p, [], from: 3.1, to: 6, width: 2400, height: 1012)
        XCTAssertEqual(sent.count, 1)
        assertNear(sent.first?.at, 4.1, "a second after the new size")
    }

    func testMergingKeepsSixAlignedDisjointRectsCoveringEveryChange() {
        var p = planner()
        // Glyphs scattered over eight places, typed in one burst.
        let spots = [(40, 40), (900, 60), (1500, 80), (60, 500), (950, 520), (1700, 540), (300, 1000), (1200, 1010)]
        let events = spots.enumerated().flatMap { i, s -> [Event] in
            let t = 2 + Double(i) * 0.1
            return [.input(t), .change(t + 0.05, PixelRect(x0: s.0, y0: s.1, x1: s.0 + 9, y1: s.1 + 17))]
        }
        let sent = run(&p, events, to: 3.5)
        guard let rects = sent.last?.refresh.rects else { return XCTFail("no region refresh") }
        XCTAssertEqual(rects.count, 6)
        for r in rects {
            XCTAssertTrue(r.x0 % 16 == 0 && r.y0 % 16 == 0 && r.x1 % 16 == 0 && (r.y1 % 16 == 0 || r.y1 == 1080), "\(r) aligned")
            for o in rects where o != r { XCTAssertTrue(r.intersection(o).isEmpty, "\(r) and \(o) overlap") }
        }
        for s in spots {
            let glyph = PixelRect(x0: s.0, y0: s.1, x1: s.0 + 9, y1: s.1 + 17)
            XCTAssertTrue(rects.contains { $0.contains(glyph) }, "\(glyph) not covered by \(rects)")
        }
    }

    func testAddMergesOverlapsAndExactNeighboursOnly() {
        var rects: [PixelRect] = []
        RefreshPlanner.add(PixelRect(x0: 0, y0: 0, x1: 16, y1: 16), to: &rects)
        RefreshPlanner.add(PixelRect(x0: 16, y0: 0, x1: 32, y1: 16), to: &rects) // next block of a line
        RefreshPlanner.add(PixelRect(x0: 32, y0: 16, x1: 48, y1: 32), to: &rects) // diagonal: stays apart
        XCTAssertEqual(rects, [PixelRect(x0: 0, y0: 0, x1: 32, y1: 16), PixelRect(x0: 32, y0: 16, x1: 48, y1: 32)])
        RefreshPlanner.add(PixelRect(x0: 8, y0: 8, x1: 40, y1: 24), to: &rects) // overlaps both
        XCTAssertEqual(rects, [PixelRect(x0: 0, y0: 0, x1: 48, y1: 32)])
        // The list stays bounded.
        var many: [PixelRect] = []
        for i in 0..<100 { RefreshPlanner.add(PixelRect(x0: i * 32, y0: i * 32 % 1024, x1: i * 32 + 16, y1: i * 32 % 1024 + 16), to: &many) }
        XCTAssertLessThanOrEqual(many.count, RefreshPlanner.trackedRects)
    }

    func testParamsEncodeAsTheFirmwareTakesThem() throws {
        let refresh = RefreshPlanner.Refresh(rects: [PixelRect(x0: 16, y0: 32, x1: 48, y1: 48)], qp: 1, frames: 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(String(decoding: try encoder.encode(refresh.params), as: UTF8.self),
                       #"{"frames":2,"qp":1,"rects":[{"h":16,"w":32,"x":16,"y":32}]}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(RefreshPlanner.Refresh(rects: [], qp: 4, frames: 2).params), as: UTF8.self),
                       #"{"frames":2,"qp":4,"rects":[]}"#)
    }

    func testLANLikeLinks() {
        XCTAssertTrue(RefreshPlanner.isLANLike(path: "lan", rttMs: 30))
        XCTAssertTrue(RefreshPlanner.isLANLike(path: "loopback", rttMs: 0))
        XCTAssertTrue(RefreshPlanner.isLANLike(path: "tailscale", rttMs: 2))
        XCTAssertFalse(RefreshPlanner.isLANLike(path: "tailscale", rttMs: 25))
        XCTAssertFalse(RefreshPlanner.isLANLike(path: "internet", rttMs: 0))
        XCTAssertFalse(RefreshPlanner.isLANLike(path: nil, rttMs: 0))
    }
}
