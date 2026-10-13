import XCTest
import JetKVMCore
@testable import BlitzKVM

final class AudioDecoderTests: XCTestCase {
    /// Decodes packets and returns the left channel; both channels must match
    /// (the tones are mono).
    func decode(_ packets: [Data], codec: AudioPacketHeader.Codec) throws -> [Float] {
        let decoder = try XCTUnwrap(AudioDecoder(codec: codec))
        var left: [Float] = []
        for packet in packets {
            let samples = try XCTUnwrap(decoder.decode(packet))
            for i in stride(from: 0, to: samples.count, by: 2) {
                XCTAssertEqual(samples[i], samples[i + 1], accuracy: 1e-4) // Opus joint stereo rounds
                left.append(samples[i])
            }
        }
        return left
    }

    /// The tone's frequency from its zero crossings.
    func frequency(_ samples: [Float]) -> Double {
        var crossings = 0
        for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(samples.count) / AudioJitterBuffer.sampleRate)
    }

    /// The emulator's Opus tone (a second of 440 Hz, 20 ms frames).
    func testDecodesOpus() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../pkg/emulator/tone.opus")
        let packets = Array(oggPackets(try Data(contentsOf: url)).dropFirst(2)) // OpusHead, OpusTags
        XCTAssertEqual(packets.count, 51)
        let samples = try decode(packets, codec: .opus)
        XCTAssertEqual(samples.count, 51 * 960, accuracy: 960)
        let middle = Array(samples[4800..<43200]) // the encoder pads both ends
        XCTAssertEqual(frequency(middle), 440, accuracy: 3)
        // ffmpeg's sine is 1/8, made stereo at -3 dB.
        XCTAssertEqual(middle.map(abs).max() ?? 0, 0.125 * 0.707, accuracy: 0.01)
    }

    /// PCMU: 8 kHz mono, upsampled to 48 kHz stereo.
    func testDecodesPCMU() throws {
        let tone = (0..<8000).map { 0.5 * sin(2 * Double.pi * 440 * Double($0) / 8000) }
        let codes = tone.map { x in UInt8((0...255).min { abs(Double(MuLaw.table[$0]) - x) < abs(Double(MuLaw.table[$1]) - x) }!) }
        let packets = stride(from: 0, to: codes.count, by: 160).map { Data(codes[$0..<$0 + 160]) }
        let samples = try decode(packets, codec: .pcmu)
        XCTAssertEqual(samples.count, 48000, accuracy: 200) // less the resampler's delay
        XCTAssertEqual(frequency(Array(samples[4800...])), 440, accuracy: 3)
        XCTAssertEqual(samples[4800...].map(abs).max() ?? 0, 0.5, accuracy: 0.03)
    }

    func oggPackets(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var packets: [Data] = []
        var packet = Data()
        var p = 0
        while p + 27 <= b.count, b[p..<p + 4].elementsEqual("OggS".utf8) {
            let segments = Int(b[p + 26])
            var body = p + 27 + segments
            for s in 0..<segments {
                let size = Int(b[p + 27 + s])
                packet.append(contentsOf: b[body..<body + size])
                body += size
                if size < 255 {
                    packets.append(packet)
                    packet = Data()
                }
            }
            p = body
        }
        return packets
    }
}
