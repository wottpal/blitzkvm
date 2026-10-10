import XCTest
@testable import JetKVMCore

final class EngineProtocolTests: XCTestCase {
    func testFramesRoundTripAcrossChunkBoundaries() throws {
        var stream = Data()
        stream.append(EngineProtocol.key(hid: 4, pressed: true))
        stream.append(EngineProtocol.absolutePointer(x: 16000, y: -1, buttons: 1))
        stream.append(EngineProtocol.wheel(y: -2, x: 1))

        var parser = FrameParser()
        var frames: [(FrameType?, Data)] = []
        // Feed one byte at a time: pipes deliver arbitrary chunks.
        for byte in stream {
            frames += try parser.feed(Data([byte]))
        }
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0].0, .key)
        XCTAssertEqual([UInt8](frames[0].1), [4, 1])
        XCTAssertEqual(frames[1].0, .absPointer)
        XCTAssertEqual([UInt8](frames[1].1), [0, 0, 0x3e, 0x80, 0xff, 0xff, 0xff, 0xff, 1])
        XCTAssertEqual([UInt8](frames[2].1), [0xfe, 1])
    }

    func testRejectsOversizedFrames() {
        var parser = FrameParser()
        XCTAssertThrowsError(try parser.feed(Data([0x7f, 0xff, 0xff, 0xff])))
    }

    func testParsesAccessUnitHeader() {
        var payload = Data([2, 1, 0, 0, 0x30, 0x39])
        payload.append(contentsOf: [0, 0, 0, 0, 0, 0, 0x03, 0xe8])
        payload.append(contentsOf: [0, 0, 0, 1, 0x26])
        guard let (header, data) = AccessUnitHeader.parse(payload) else {
            return XCTFail("parse failed")
        }
        XCTAssertEqual(header.codec, .h265)
        XCTAssertTrue(header.keyframe)
        XCTAssertEqual(header.rtpTimestamp, 12345)
        XCTAssertEqual(header.receivedUnixNano, 1000)
        XCTAssertEqual([UInt8](data), [0, 0, 0, 1, 0x26])
    }

    func testCommandEncodesLikeGo() throws {
        let data = try JSONEncoder().encode(EngineCommand(id: 7, cmd: "connect", baseURL: "jetkvm.local", offerH265: true))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["cmd"] as? String, "connect")
        XCTAssertEqual(object["baseURL"] as? String, "jetkvm.local")
        XCTAssertEqual(object["offerH265"] as? Bool, true)
        XCTAssertNil(object["password"])
    }
}

final class AnnexBTests: XCTestCase {
    func testSplitsH264ParameterSetsAndPrefixesSlices() {
        let au = Data([0, 0, 0, 1, 0x09, 0xf0, // AUD
                       0, 0, 0, 1, 0x67, 0x64, 0x1f, // SPS
                       0, 0, 1, 0x68, 0xee, // PPS
                       0, 0, 0, 1, 0x65, 0x88, 0x84]) // IDR
        let split = AnnexB.split(au, codec: .h264)
        XCTAssertEqual(split.parameterSets.map { [UInt8]($0) }, [[0x67, 0x64, 0x1f], [0x68, 0xee]])
        XCTAssertEqual([UInt8](split.lengthPrefixed), [0, 0, 0, 3, 0x65, 0x88, 0x84])
        XCTAssertTrue(split.isKeyframe)
    }

    func testSplitsH265ParameterSets() {
        let au = Data([0, 0, 0, 1, 0x40, 0x01, // VPS (32)
                       0, 0, 0, 1, 0x42, 0x01, // SPS (33)
                       0, 0, 0, 1, 0x44, 0x01, // PPS (34)
                       0, 0, 0, 1, 0x26, 0x01, 0xaf]) // IDR_W_RADL (19)
        let split = AnnexB.split(au, codec: .h265)
        XCTAssertEqual(split.parameterSets.count, 3)
        XCTAssertTrue(split.isKeyframe)
        XCTAssertEqual([UInt8](split.lengthPrefixed), [0, 0, 0, 3, 0x26, 0x01, 0xaf])
    }

    func testPFrameIsNotKeyframe() {
        let split = AnnexB.split(Data([0, 0, 1, 0x41, 0x9a]), codec: .h264)
        XCTAssertFalse(split.isKeyframe)
        XCTAssertTrue(split.parameterSets.isEmpty)
    }
}

final class KeyMapTests: XCTestCase {
    func testLettersAndModifiers() {
        XCTAssertEqual(KeyMap.hidUsage(keyCode: 0x00, isISO: false), 0x04) // A
        XCTAssertEqual(KeyMap.hidUsage(keyCode: 0x24, isISO: false), 0x28) // Return
        XCTAssertEqual(KeyMap.modifierUsage[0x37], 0xE3) // left ⌘ → left GUI
        XCTAssertEqual(KeyMap.modifierUsage[0x3D], 0xE6) // right ⌥ → AltGr
    }

    func testISOKeyboardSwapsSectionAndGrave() {
        // Top-left key (§ / ^) must be the PC grave position on ISO boards.
        XCTAssertEqual(KeyMap.hidUsage(keyCode: 0x0A, isISO: true), 0x35)
        XCTAssertEqual(KeyMap.hidUsage(keyCode: 0x32, isISO: true), 0x64)
        XCTAssertEqual(KeyMap.hidUsage(keyCode: 0x32, isISO: false), 0x35)
    }

    func testPCProfileSwapsCommandAndControl() {
        XCTAssertEqual(ModifierProfile.pc.apply(0xE3), 0xE0)
        XCTAssertEqual(ModifierProfile.pc.apply(0xE0), 0xE3)
        XCTAssertEqual(ModifierProfile.mac.apply(0xE3), 0xE3)
        XCTAssertEqual(ModifierProfile.pc.apply(0x04), 0x04)
    }
}

final class GeometryTests: XCTestCase {
    func testFitLetterboxesAndSnaps() {
        let layout = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080, drawableWidth: 2000, drawableHeight: 2000, mode: .fit)
        XCTAssertEqual(layout.width, 2000)
        XCTAssertEqual(layout.height, 1125)
        XCTAssertEqual(layout.y, 437)
        XCTAssertFalse(layout.nearest)
    }

    func testActualSizeIsPixelExact() {
        let layout = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080, drawableWidth: 3024, drawableHeight: 1964, mode: .actualSize)
        XCTAssertEqual(layout.width, 1920)
        XCTAssertEqual(layout.x, 552)
        XCTAssertTrue(layout.nearest)
    }

    func testIntegerScaleUsesWholeMultiples() {
        let layout = VideoLayout.compute(videoWidth: 1280, videoHeight: 720, drawableWidth: 3000, drawableHeight: 2000, mode: .integer)
        XCTAssertEqual(layout.width, 2560)
        XCTAssertTrue(layout.nearest)
    }

    func testAbsolutePositionClampsToVideo() {
        let layout = VideoLayout(x: 100, y: 50, width: 1000, height: 500, nearest: false)
        XCTAssertEqual(layout.absolutePosition(px: 100, py: 50)?.0, 0)
        XCTAssertEqual(layout.absolutePosition(px: 1100, py: 550)?.1, 32767)
        XCTAssertEqual(layout.absolutePosition(px: 600, py: 300)?.0, 16384)
        XCTAssertEqual(layout.absolutePosition(px: -50, py: 9000)?.1, 32767)
    }

    func testScrollAccumulatorKeepsFractions() {
        var acc = ScrollAccumulator(pointsPerTick: 10)
        var total = 0
        for _ in 0..<25 {
            total += Int(acc.add(deltaX: 0, deltaY: 1, precise: true).y)
        }
        XCTAssertEqual(total, 2, "25 points at 10 points per tick is 2 ticks, remainder kept")
        XCTAssertEqual(acc.add(deltaX: 0, deltaY: 5, precise: true).y, 1)
        XCTAssertEqual(acc.add(deltaX: 0, deltaY: -3, precise: false).y, -3)
    }
}

final class BarcodeTests: XCTestCase {
    func testDecodesEmulatorBarcode() {
        let width = 640, height = 16
        var luma = [UInt8](repeating: 16, count: width * height)
        func cell(_ i: Int, _ v: UInt8) {
            for y in 0..<8 { for x in 0..<8 { luma[y * width + i * 8 + x] = v } }
        }
        let ms: Int64 = 1_760_000_000_123
        cell(0, 235); cell(1, 16)
        for i in 0..<48 { cell(i + 2, (ms >> (47 - i)) & 1 == 1 ? 235 : 16) }
        let decoded = luma.withUnsafeBufferPointer {
            TimestampBarcode.decode(luma: $0.baseAddress!, stride: width, width: width, height: height)
        }
        XCTAssertEqual(decoded, ms)
    }
}

final class DeviceLibraryTests: XCTestCase {
    func testStoreRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("devices.json")
        let store = DeviceStore(url: url)
        var device = Device(name: "Server", addresses: ["10.0.0.5", "server.tailnet.ts.net"], deviceID: "abc")
        device.lastConnected = Date(timeIntervalSince1970: 1_760_000_000)
        store.upsert(device)
        try store.save()
        let reloaded = DeviceStore(url: url)
        XCTAssertEqual(reloaded.devices, [device])
        XCTAssertEqual(reloaded.device(matchingAddress: "SERVER.tailnet.ts.net")?.id, device.id)
        XCTAssertEqual(device.credentialAccount, "abc")
    }

    func testParseAddresses() {
        XCTAssertEqual(Device.parseAddresses(" 10.0.0.5, jetkvm.local  kvm.ts.net\n"), ["10.0.0.5", "jetkvm.local", "kvm.ts.net"])
    }

    func testProbePrefersEarlierAddressWithinWindow() async {
        // The VPN name answers first, the LAN IP (preferred) shortly after.
        let result = await AddressProbe.choose(addresses: ["lan", "vpn"], expectedDeviceID: "dev") { address in
            try? await Task.sleep(for: .milliseconds(address == "lan" ? 60 : 10))
            return DeviceIdentity(deviceId: "dev", authMode: nil)
        }
        XCTAssertEqual(try? result.get().address, "lan")
    }

    func testProbeFallsBackWhenPreferredIsDown() async {
        let result = await AddressProbe.choose(addresses: ["lan", "vpn"], expectedDeviceID: nil, preferenceWindow: .milliseconds(50)) { address in
            if address == "lan" {
                try? await Task.sleep(for: .seconds(5)) // unreachable: times out
                return nil
            }
            return DeviceIdentity(deviceId: "dev", authMode: nil)
        }
        XCTAssertEqual(try? result.get().address, "vpn")
    }

    func testProbeAcceptsUnknownIdentityBehindLogin() async {
        // Password-protected firmware answers GET /device only after login.
        let result = await AddressProbe.choose(addresses: ["lan"], expectedDeviceID: "real") { _ in
            DeviceIdentity(deviceId: nil, authMode: "password")
        }
        XCTAssertEqual(try? result.get().address, "lan")
        XCTAssertNil(try? result.get().identity.deviceId)
    }

    func testProbePrefersConfirmedIdentityOverUnknown() async {
        // The LAN address now answers 401 (another, password-protected
        // device); the VPN name confirms the saved ID.
        let result = await AddressProbe.choose(addresses: ["lan", "vpn"], expectedDeviceID: "dev", preferenceWindow: .milliseconds(100)) { address in
            if address == "lan" { return DeviceIdentity(deviceId: nil, authMode: "password") }
            try? await Task.sleep(for: .milliseconds(20))
            return DeviceIdentity(deviceId: "dev", authMode: nil)
        }
        XCTAssertEqual(try? result.get().address, "vpn")
    }

    func testProbeRejectsImpostor() async {
        let result = await AddressProbe.choose(addresses: ["evil"], expectedDeviceID: "real") { _ in
            DeviceIdentity(deviceId: "other", authMode: "password")
        }
        guard case .failure(.identityMismatch(expected: "real", found: "other")) = result else {
            return XCTFail("impostor accepted: \(result)")
        }
    }
}
