import AVFoundation
import JetKVMCore

/// Plays the device's audio. Packets are decoded on the player's own queue,
/// apart from video and input (Opus with AVAudioConverter, PCMU with the
/// µ-law table and AVAudioConverter's resampler, both to 48 kHz stereo), into
/// a jitter buffer (AudioJitterBuffer) that an AVAudioEngine source node
/// drains. The engine runs only while there is sound: it starts with the
/// first audible packet and stops `idleTimeout` after the last, so silence
/// costs nothing.
final class AudioPlayer {
    struct Stats {
        var codec: String?
        var packets = 0
        var bytes = 0
        /// Packets missing from the sequence, and ones that came too late.
        var lost = 0
        var late = 0
        var decodeErrors = 0
        var engineStarts = 0
        var buffer = AudioJitterBuffer.Stats()
        /// Latency sound starts with after silence, and measured from a
        /// packet's arrival in the app to its output (p50, p95), seconds.
        var target = 0.0
        var delays: [Double] = []
        /// From the helper's receipt of a packet to the app's (ms, sorted).
        var ipcMs: [Double] = []
        /// Time decoding a packet (µs, sorted); share of a core spent
        /// decoding and rendering while the engine ran.
        var decodeMicros: [Double] = []
        var cpuShare = 0.0
    }

    /// Without a packet with sound for this long, the engine stops.
    static let idleTimeout = 3.0
    /// Quieter packets (-80 dBFS) do not start the engine.
    private static let audible: Float = 1e-4

    private let queue = DispatchQueue(label: "jetkvm.audio", qos: .userInteractive)
    /// The jitter buffer, shared with the render thread, the time spent
    /// rendering, and how long after a buffer reaches the device it is heard.
    private let render = Locked((buffer: AudioJitterBuffer(), nanos: UInt64(0), latency: 0.0))
    private let counters = Locked(Stats())
    // Queue state.
    private var enabled = false
    private var muted = false
    /// Built on the first sound and kept (only starting it is quick), and
    /// whether it runs.
    private var engine: AVAudioEngine?
    private var running = false
    private var engineStartedAt: UInt64 = 0
    private var busyNanos: UInt64 = 0
    private var runNanos: UInt64 = 0
    private var retryStartAt: UInt64 = 0
    private var decoder: AudioDecoder?
    private var last: AudioPacketHeader?
    private var lastSound: UInt64 = 0
    private var idleTimer: DispatchSourceTimer?
    private var configObserver: NSObjectProtocol?
    private var decodeMicros = [Double](repeating: 0, count: 256)
    private var ipcMs = [Double](repeating: 0, count: 256)

    /// Plays (Play Audio) or drops what arrives.
    func setEnabled(_ on: Bool) {
        queue.async {
            self.enabled = on
            if !on { self.stopEngine() }
        }
    }

    /// Plays at zero volume (self-tests: everything runs, nothing is heard).
    func setMuted(_ on: Bool) {
        queue.async {
            self.muted = on
            self.engine?.mainMixerNode.outputVolume = on ? 0 : 1
        }
    }

    func stop() { setEnabled(false) }

    /// The session reconnected: the next packet starts a new RTP stream.
    func streamEnded() {
        queue.async { self.last = nil }
    }

    /// The codec while sound plays (status bar).
    var playingCodec: String? {
        counters.withLock { $0.codec }.flatMap { codec in render.withLock { $0.buffer.isIdle } ? nil : codec }
    }

    func stats() -> Stats {
        var stats = counters.withLock { $0 }
        render.withLock {
            stats.buffer = $0.buffer.stats
            stats.target = $0.buffer.target
            stats.delays = $0.buffer.recentDelays()
        }
        return stats
    }

    /// An audio frame from the helper (header and payload). Called on the
    /// helper's I/O queue: only stamps the arrival and hands over.
    func receive(_ frame: Data) {
        let arrival = DispatchTime.now().uptimeNanoseconds
        queue.async { self.handle(frame, arrival: arrival) }
    }

    private func handle(_ frame: Data, arrival: UInt64) {
        guard enabled, let (header, payload) = AudioPacketHeader.parse(frame) else { return }
        let ipc = Date().timeIntervalSince1970 * 1000 - Double(header.receivedUnixNano) / 1e6
        // A talkspurt starts with a marker and a timestamp that skipped the
        // silence (fork firmware). Stock firmware marks every packet and its
        // timestamp runs on: the jitter buffer tells its talkspurts by time.
        var starts = true
        if let last, header.codec == last.codec {
            let step = Int16(bitPattern: header.sequenceNumber &- last.sequenceNumber)
            if step <= 0, step > -100 {
                counters.withLock { $0.late += 1 }
                return
            }
            if step > 1, step < 100 {
                counters.withLock { $0.lost += Int(step) - 1 }
            }
            let skipped = Int(header.rtpTimestamp &- last.rtpTimestamp) > header.codec.clockRate * 3 / 100 * Int(step) // 30 ms a packet
            starts = step >= 100 || header.marker && skipped
        }
        last = header
        if decoder?.codec != header.codec {
            decoder = AudioDecoder(codec: header.codec)
            AppLog.log("audio: \(header.codec.name)")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let samples = decoder?.decode(payload)
        let decodeNanos = DispatchTime.now().uptimeNanoseconds - started
        let count = counters.withLock { stats -> Int in
            stats.codec = header.codec.name
            stats.packets += 1
            stats.bytes += payload.count
            if samples == nil { stats.decodeErrors += 1 }
            return stats.packets
        }
        decodeMicros[count % decodeMicros.count] = Double(decodeNanos) / 1000
        ipcMs[count % ipcMs.count] = ipc
        guard let samples else { return }
        let audible = samples.contains { abs($0) > Self.audible }
        if !running {
            guard audible, startEngine() else { return }
        }
        busyNanos += decodeNanos
        if audible { lastSound = arrival }
        let time = Self.seconds(arrival)
        render.withLock { $0.buffer.push(samples, arrival: time, starts: starts) }
    }

    // MARK: Engine

    /// The engine: a source node that drains the jitter buffer.
    private func makeEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: AudioJitterBuffer.sampleRate, channels: 2)!
        let render = self.render
        let source = AVAudioSourceNode(format: format) { _, timestamp, frames, list in
            let start = mach_absolute_time()
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count == 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return kAudioUnitErr_FormatNotSupported }
            let now = AudioPlayer.seconds(fromHostTime: start)
            let ts = timestamp.pointee
            // When this buffer reaches the device.
            let output = ts.mFlags.contains(.hostTimeValid) ? AudioPlayer.seconds(fromHostTime: ts.mHostTime) : now
            render.withLock {
                $0.buffer.pull(left: left, right: right, count: Int(frames), at: output + $0.latency, now: now)
                $0.nanos += AudioPlayer.nanos(fromHostTime: mach_absolute_time() - start)
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        // The output device changed (or went away): the engine stopped, and
        // is built anew for the next sound.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async {
                self?.stopEngine()
                self?.discardEngine()
            }
        }
        return engine
    }

    private func discardEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine = nil
    }

    private func startEngine() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= retryStartAt else { return false }
        let engine = self.engine ?? makeEngine()
        self.engine = engine
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
        do {
            try engine.start()
        } catch {
            AppLog.log("audio: the output did not start (\(error.localizedDescription)); trying again in 10 s")
            retryStartAt = now + 10_000_000_000
            discardEngine()
            return false
        }
        running = true
        // Heard this long after a buffer reaches the device.
        let latency = engine.outputNode.presentationLatency
        render.withLock { $0.latency = latency }
        engineStartedAt = now
        counters.withLock { $0.engineStarts += 1 }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.stopWhenIdle() }
        timer.resume()
        idleTimer = timer
        return true
    }

    /// Stops the engine once nothing audible came for `idleTimeout`, also
    /// while silent packets still come (stock firmware may send silence).
    private func stopWhenIdle() {
        if Double(DispatchTime.now().uptimeNanoseconds - lastSound) / 1e9 > Self.idleTimeout {
            stopEngine()
        }
    }

    private func stopEngine() {
        guard running else { return }
        running = false
        idleTimer?.cancel()
        idleTimer = nil
        engine?.stop()
        let rendered = render.withLock { state -> UInt64 in
            state.buffer.reset()
            defer { state.nanos = 0 }
            return state.nanos
        }
        busyNanos += rendered
        runNanos += DispatchTime.now().uptimeNanoseconds - engineStartedAt
        let share = Double(busyNanos) / Double(max(runNanos, 1))
        counters.withLock { $0.cpuShare = share }
    }

    /// Percentiles and CPU need the engine's current run counted too.
    func finishStats() -> Stats {
        queue.sync {
            stopEngine()
            counters.withLock {
                $0.decodeMicros = Array(decodeMicros.prefix(min($0.packets, decodeMicros.count))).sorted()
                $0.ipcMs = Array(ipcMs.prefix(min($0.packets, ipcMs.count))).sorted()
            }
        }
        return stats()
    }

    // MARK: Clock

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    static func nanos(fromHostTime t: UInt64) -> UInt64 { UInt64(Double(t) * timebase) }
    static func seconds(fromHostTime t: UInt64) -> Double { Double(t) * timebase / 1e9 }
    /// DispatchTime's uptime (the same clock as mach_absolute_time).
    static func seconds(_ uptimeNanos: UInt64) -> Double { Double(uptimeNanos) / 1e9 }
}

/// Decodes one codec's packets to 48 kHz stereo Float32, interleaved.
final class AudioDecoder {
    let codec: AudioPacketHeader.Codec
    private let converter: AVAudioConverter
    private let input: AVAudioBuffer
    private let output: AVAudioPCMBuffer

    init?(codec: AudioPacketHeader.Codec) {
        guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioJitterBuffer.sampleRate, channels: 2, interleaved: true),
              let output = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: 5760) else { return nil } // 120 ms, Opus's longest
        let input: AVAudioBuffer
        switch codec {
        case .opus:
            var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                                   mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
            guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
            input = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: 1500)
        case .pcmu:
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1500) else { return nil }
            input = buffer
        }
        guard let converter = AVAudioConverter(from: input.format, to: out) else { return nil }
        self.codec = codec
        self.converter = converter
        self.input = input
        self.output = output
    }

    /// Decodes one packet; the samples stay valid until the next call.
    func decode(_ payload: Data) -> UnsafeBufferPointer<Float>? {
        guard payload.count <= 1500, !payload.isEmpty else { return nil }
        switch input {
        case let opus as AVAudioCompressedBuffer:
            payload.withUnsafeBytes { opus.data.copyMemory(from: $0.baseAddress!, byteCount: payload.count) }
            opus.byteLength = UInt32(payload.count)
            opus.packetCount = 1
            opus.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))
        case let pcm as AVAudioPCMBuffer:
            let samples = pcm.floatChannelData![0]
            for (i, code) in payload.enumerated() { samples[i] = MuLaw.table[Int(code)] }
            pcm.frameLength = AVAudioFrameCount(payload.count)
        default:
            return nil
        }
        output.frameLength = 0
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { [input] _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard status != .error, let data = output.floatChannelData?[0] else { return nil }
        return UnsafeBufferPointer(start: data, count: Int(output.frameLength) * 2)
    }
}
