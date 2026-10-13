import XCTest
@testable import JetKVMCore

final class AudioTests: XCTestCase {
    func testMuLawDecodesG711() {
        XCTAssertEqual(MuLaw.linear(0xff), 0)
        XCTAssertEqual(MuLaw.linear(0x7f), 0)
        XCTAssertEqual(MuLaw.linear(0x80), 32124)
        XCTAssertEqual(MuLaw.linear(0x00), -32124)
        XCTAssertEqual(MuLaw.linear(0xef), 132) // exponent 1, mantissa 0: 132 * 2 - 132
        XCTAssertEqual(MuLaw.linear(0xfe), 8)
        // Codes 0x80...0xff run from the loudest positive sample down to 0,
        // the 0x00...0x7f mirror them.
        for code in 0x80..<0xff {
            XCTAssertGreaterThan(MuLaw.linear(UInt8(code)), MuLaw.linear(UInt8(code + 1)))
            XCTAssertEqual(MuLaw.linear(UInt8(code)), -MuLaw.linear(UInt8(code - 0x80)))
        }
        XCTAssertEqual(MuLaw.table[0x80], 32124 / 32768, accuracy: 1e-6)
    }

    func testHeaderParses() {
        var payload = Data([1, 1, 0xff, 0xfe, 0xde, 0xad, 0xbe, 0xef, 0, 0, 0, 0, 0, 0, 0x03, 0xe8])
        payload.append(contentsOf: [0xfc, 0xff])
        guard let (header, data) = AudioPacketHeader.parse(payload) else { return XCTFail("parse failed") }
        XCTAssertEqual(header, AudioPacketHeader(codec: .opus, marker: true, sequenceNumber: 0xfffe, rtpTimestamp: 0xdeadbeef, receivedUnixNano: 1000))
        XCTAssertEqual([UInt8](data), [0xfc, 0xff])
        XCTAssertNil(AudioPacketHeader.parse(payload.prefix(15)))
        payload[0] = 9
        XCTAssertNil(AudioPacketHeader.parse(payload), "unknown codec")
    }

    // MARK: Jitter buffer

    static let rate = AudioJitterBuffer.sampleRate
    /// An output like the Mac's: 512 frames per pull, each heard 11.6 ms
    /// after it is pulled.
    static let quantum = 512
    static let outputLatency = 0.0116

    struct Packet {
        var arrival: Double
        var starts: Bool
        var value: Float = 0.5
    }

    struct Run {
        var left: [Float] = []
        /// Wall time of each pull.
        var pulls: [Double] = []
        var buffer: AudioJitterBuffer
        var maxStep: Float = 0

        /// Output time of left[i].
        func outputTime(_ i: Int) -> Double {
            pulls[i / AudioTests.quantum] + AudioTests.outputLatency + Double(i % AudioTests.quantum) / AudioTests.rate
        }
    }

    /// Plays packets through a buffer until `end`. Each packet is a
    /// constant (0.5), so any click shows as a step between samples.
    func play(_ packets: [Packet], until end: Double, outputFrom: Double = 0, buffer: AudioJitterBuffer = AudioJitterBuffer()) -> Run {
        var run = Run(buffer: buffer)
        var pending = packets.sorted { $0.arrival < $1.arrival }[...]
        var right = [Float](repeating: 0, count: Self.quantum)
        var out = [Float](repeating: 0, count: Self.quantum)
        var last: Float = 0
        var t = outputFrom
        while t < end {
            while let p = pending.first, p.arrival <= t {
                pending.removeFirst()
                let samples = [Float](repeating: p.value, count: 2 * 960)
                samples.withUnsafeBufferPointer { run.buffer.push($0, arrival: p.arrival, starts: p.starts) }
            }
            out.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    run.buffer.pull(left: l.baseAddress!, right: r.baseAddress!, count: Self.quantum, at: t + Self.outputLatency, now: t)
                }
            }
            for x in out {
                run.maxStep = max(run.maxStep, abs(x - last))
                last = x
            }
            run.left += out
            run.pulls.append(t)
            t += Double(Self.quantum) / Self.rate
        }
        return run
    }

    /// A stream of 20 ms packets sent from `start` for `seconds`; the
    /// device's clock runs `skew` fast (0.001: 0.1 %).
    func stream(from start: Double, seconds: Double, skew: Double = 0) -> [Packet] {
        (0..<Int(seconds * 50)).map { Packet(arrival: start + Double($0) * 0.02 / (1 + skew), starts: $0 == 0) }
    }

    func median(_ values: [Double]) -> Double { values.isEmpty ? .nan : values[values.count / 2] }

    func testSoundStartsAtTheTargetAfterItArrives() {
        let run = play([Packet(arrival: 0.5, starts: true)], until: 1)
        let first = run.left.firstIndex { $0 != 0 }!
        // Its slack is the margin: 15 ms before the pull its frame needs.
        XCTAssertEqual(run.buffer.target, 0.015 + Self.outputLatency + Double(Self.quantum) / Self.rate, accuracy: 1e-9)
        XCTAssertEqual(run.outputTime(first), 0.5 + run.buffer.target, accuracy: 0.001)
        XCTAssertEqual(run.buffer.stats.playedFrames, 960)
        XCTAssertEqual(run.buffer.stats.starts, 1)
        XCTAssertEqual(run.buffer.stats.underruns, 1, "ran dry after the packet")
        XCTAssertTrue(run.buffer.isIdle)
    }

    func testSteadyStreamPlaysEverythingOnTime() {
        let run = play(stream(from: 0.3, seconds: 5), until: 6)
        let s = run.buffer.stats
        XCTAssertEqual(s.playedFrames, 250 * 960)
        XCTAssertEqual(s.underruns, 1, "only at the end")
        XCTAssertEqual(s.skippedFrames + s.repeatedFrames + s.overflowFrames, 0)
        XCTAssertEqual(median(run.buffer.recentDelays()), run.buffer.target, accuracy: 0.002)
        XCTAssertLessThanOrEqual(run.maxStep, 0.5 / 240 + 1e-6, "fades only, no clicks")
    }

    /// Opus DTX sends a packet every 400 ms during silence: each plays
    /// (comfort noise), fading in and out, without a click.
    func testDiscontinuousTransmissionPlaysWithoutClicks() {
        let packets = (0..<10).map { Packet(arrival: 0.2 + Double($0) * 0.4, starts: $0 == 0) }
        let run = play(packets, until: 4.5)
        let s = run.buffer.stats
        XCTAssertEqual(s.starts + s.stalls, 10)
        XCTAssertEqual(s.underruns, 10)
        XCTAssertEqual(s.playedFrames, 9600)
        XCTAssertLessThanOrEqual(run.maxStep, 0.5 / 240 + 1e-6)
        XCTAssertEqual(run.buffer.targetSlack, run.buffer.margin, "silence is no reason for more latency")
    }

    /// The device holds its packets for 0.5 s every 6 s, then sends them
    /// at once. The first stall is a gap; the latency then covers the next
    /// ones, and comes back down 20 s after the stalls stop.
    func testStallsRaiseLatencyUntilTheyStop() {
        var packets = stream(from: 0.2, seconds: 70)
        for i in packets.indices {
            let t = packets[i].arrival
            if t < 25, t.truncatingRemainder(dividingBy: 6) >= 5.5 {
                packets[i].arrival = t - t.truncatingRemainder(dividingBy: 6) + 6
            }
        }
        var run = play(packets, until: 24)
        XCTAssertEqual(run.buffer.stats.stalls, 1, "only the first stall runs dry")
        XCTAssertEqual(run.buffer.stats.underruns, 1)
        XCTAssertGreaterThanOrEqual(run.buffer.target, 0.5)
        XCTAssertLessThanOrEqual(run.buffer.target, 0.6)
        XCTAssertGreaterThan(median(run.buffer.recentDelays()), 0.45)

        run = play(packets, until: 71)
        XCTAssertEqual(run.buffer.stats.stalls, 1)
        XCTAssertLessThan(run.buffer.target, 0.07)
        XCTAssertLessThan(median(run.buffer.recentDelays()), 0.08, "latency cut once the stalls stopped")
        XCTAssertGreaterThan(run.buffer.stats.skippedFrames, Int(0.4 * Self.rate))
        XCTAssertEqual(run.buffer.stats.playedFrames, 3500 * 960 - run.buffer.stats.skippedFrames + run.buffer.stats.repeatedFrames,
                       "everything else played")
    }

    /// The device's clock runs 0.2 % fast, then 0.2 % slow (20 times what
    /// clocks drift): 120 ms in a minute. The latency stays bounded, by
    /// small skips or repeats, without running dry. Skips wait until 20 s
    /// of packets agree, so a fast clock runs up to 40 ms ahead first.
    func testClockDriftIsAbsorbed() {
        for skew in [0.002, -0.002] {
            let run = play(stream(from: 0.2, seconds: 60, skew: skew), until: 61)
            let s = run.buffer.stats
            XCTAssertEqual(s.underruns, 1, "skew \(skew): only at the end")
            XCTAssertEqual(s.stalls, 0)
            XCTAssertGreaterThan(skew > 0 ? s.skippedFrames : s.repeatedFrames, Int(0.06 * Self.rate), "skew \(skew)")
            XCTAssertEqual(skew > 0 ? s.repeatedFrames : s.skippedFrames, 0, "skew \(skew)")
            let delays = run.buffer.recentDelays()
            XCTAssertGreaterThan(delays.first!, Self.outputLatency + Double(Self.quantum) / Self.rate, "skew \(skew): never late for its pull")
            XCTAssertLessThan(delays.last!, 0.1, "skew \(skew)")
        }
    }

    /// Each talkspurt starts `target` after its first packet arrived, also
    /// while the one before still plays: its tail is cut (faded out) or
    /// padded with silence, so the old timing is not carried over (a Mac
    /// that restarts its USB audio sends the next one up to 100 ms late).
    func testTalkspurtsAreAnchoredAnew() {
        // The first talkspurt's latency rose by a 0.3 s stall; the next
        // arrives 0.1 s after its last packet, while its tail still plays.
        var first = stream(from: 0.2, seconds: 2)
        for i in first.indices where (0.8..<1.1).contains(first[i].arrival) { first[i].arrival = 1.1 }
        // Or with the usual latency, 5 ms after its last packet: overlapping.
        for (gap, stalled) in [(0.1, true), (0.005, false)] {
            let firstPackets = stalled ? first : stream(from: 0.2, seconds: 2)
            let start = firstPackets.last!.arrival + gap
            let second = stream(from: start, seconds: 0.5).map { Packet(arrival: $0.arrival, starts: $0.starts, value: -0.5) }
            let run = play(firstPackets + second, until: start + 1)
            let onset = run.left.firstIndex { $0 < 0 }!
            XCTAssertEqual(run.outputTime(onset), start + run.buffer.target + 1 / Self.rate, accuracy: 0.001, "gap \(gap)")
            XCTAssertEqual(run.buffer.stats.starts, 2)
            XCTAssertEqual(run.buffer.stats.stalls, stalled ? 1 : 0)
            XCTAssertLessThanOrEqual(run.maxStep, 0.5 / 240 + 1e-6, "gap \(gap): fades only")
            XCTAssertTrue(run.left[..<onset].allSatisfy { $0 >= 0 }, "nothing of the second before its time")
        }
    }

    /// The output starts 170 ms after the first packet (AVAudioEngine's
    /// first start): that packet plays late, but the startup is no jitter,
    /// and the latency is cut back within the talkspurt.
    func testLateOutputStartIsCaughtUp() {
        let run = play(stream(from: 0.1, seconds: 5), until: 5.2, outputFrom: 0.27)
        XCTAssertEqual(run.buffer.targetSlack, run.buffer.margin, accuracy: 0.005)
        XCTAssertGreaterThan(run.buffer.stats.skippedFrames, Int(0.1 * Self.rate))
        XCTAssertEqual(run.buffer.stats.underruns, 1)
    }

    /// A stalled output (no pulls) must not grow the buffer without bound.
    func testOverflowDropsTheOldest() {
        var buffer = AudioJitterBuffer(capacity: 1)
        let samples = [Float](repeating: 0.5, count: 1920)
        for i in 0..<100 {
            samples.withUnsafeBufferPointer { buffer.push($0, arrival: Double(i) * 0.02, starts: i == 0) }
        }
        XCTAssertEqual(buffer.buffered, 48000)
        XCTAssertEqual(buffer.stats.overflowFrames, 100 * 960 - 48000)
    }
}
