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

    func testPixelExactIsOnePhysicalPixel() {
        let layout = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080, drawableWidth: 3024, drawableHeight: 1964, mode: .pixelExact, pointScale: 2)
        XCTAssertEqual(layout.width, 1920)
        XCTAssertEqual(layout.x, 552)
        XCTAssertTrue(layout.nearest)
    }

    func testActualSizeIsOnePointPerRemotePixel() {
        // Retina: a 1080p remote is 3840 physical pixels wide, the size a
        // 1080p monitor shows it at.
        let layout = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080, drawableWidth: 6016, drawableHeight: 2400, mode: .actualSize, pointScale: 2)
        XCTAssertEqual(layout.width, 3840)
        XCTAssertEqual(layout.x, 1088)
        XCTAssertEqual(layout.y, 120)
        XCTAssertTrue(layout.nearest)
    }

    func testActualSizePansWhenLargerThanTheView() {
        let left = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080, drawableWidth: 2000, drawableHeight: 2160, mode: .actualSize, pointScale: 2, pan: (0, 0.5))
        XCTAssertEqual(left.x, 0)
        let right = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080, drawableWidth: 2000, drawableHeight: 2160, mode: .actualSize, pointScale: 2, pan: (1, 0.5))
        XCTAssertEqual(right.x, -1840)
        // The pointer at the view's right edge reaches the remote's right edge.
        XCTAssertEqual(right.absolutePosition(px: 2000, py: 0)?.0, 32767)
        let middle = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080, drawableWidth: 2000, drawableHeight: 2160, mode: .actualSize, pointScale: 2, pan: (0.5, 0.5))
        XCTAssertEqual(middle.absolutePosition(px: 1000, py: 1080)?.0, 16384)
    }

    func testPreferredContentSizeUsesPointsAndFitsTheScreen() {
        let size = preferredContentSize(videoWidth: 1920, videoHeight: 1080, pointScale: 2, mode: .actualSize, available: (3008, 1200), extraHeight: 22)
        XCTAssertEqual(size?.width, 1920)
        XCTAssertEqual(size?.height, 1102)
        let small = preferredContentSize(videoWidth: 1920, videoHeight: 1080, pointScale: 2, mode: .actualSize, available: (1512, 900), extraHeight: 22)
        XCTAssertEqual(small?.width, 1512)
        XCTAssertEqual(small?.height, 873)
        let exact = preferredContentSize(videoWidth: 1920, videoHeight: 1080, pointScale: 2, mode: .pixelExact, available: (3008, 1200), extraHeight: 22)
        XCTAssertEqual(exact?.width, 960)
    }

    func testMatchWindowIsActualSizeOnceMatchedAndFitsOtherwise() {
        // Remote took the view's size, rounded down: one pixel per point.
        let matched = VideoLayout.compute(videoWidth: 1504, videoHeight: 944, drawableWidth: 3022, drawableHeight: 1894, mode: .matchWindow, pointScale: 2)
        XCTAssertEqual([matched.x, matched.y, matched.width, matched.height], [7, 3, 3008, 1888])
        // Not yet (or beyond the device's limits): fills the view.
        let pending = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080, drawableWidth: 3008, drawableHeight: 1692, mode: .matchWindow, pointScale: 2)
        XCTAssertEqual([pending.width, pending.height], [3008, 1692])
        let larger = VideoLayout.compute(videoWidth: 1920, videoHeight: 1040, drawableWidth: 4800, drawableHeight: 2600, mode: .matchWindow, pointScale: 2)
        XCTAssertEqual([larger.width, larger.height], [4800, 2600])
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

    // MARK: Serial console, virtual media, certificate pinning

    func testSerialFilterStripsEscapesAcrossChunks() {
        var filter = SerialTextFilter()
        var out = filter.feed("\u{1B}[1;32mok\u{1B}[")
        out += filter.feed("0m done\r")
        out += filter.feed("\nnext\u{07}line\r\n\u{1B}]0;title\u{07}end")
        XCTAssertEqual(out, "ok done\nnextline\nend")
    }

    func testSerialFilterSurvivesAnUnterminatedSequence() {
        // Line noise at the wrong baud rate opens an OSC that never ends.
        var filter = SerialTextFilter()
        var out = filter.feed("noise\u{1B}]garbage")
        out += filter.feed("\nline one\nline two\n")
        XCTAssertEqual(out, "noise\nline one\nline two\n")
        var long = SerialTextFilter()
        let text = long.feed("\u{1B}[" + String(repeating: "1;", count: 200)) + long.feed("after")
        XCTAssertTrue(text.hasSuffix("after"), "a held-back sequence is bounded: \(text.suffix(20))")
    }

    func testSerialFilterLineEndingsAndCharsetEscapes() {
        var filter = SerialTextFilter()
        XCTAssertEqual(filter.feed("a\r\r\nb\u{1B}(Bc\r"), "a\nbc")
        XCTAssertEqual(filter.feed("\nd"), "\nd", "CR LF split across chunks is one line break")
    }

    func testSerialFilterTurnsLoneCarriageReturnIntoNewline() {
        var filter = SerialTextFilter()
        XCTAssertEqual(filter.feed("a\rb\n"), "a\nb\n")
    }

    func testStorageFilesDecodeGoTimes() throws {
        let json = #"{"files":[{"filename":"debian.iso","size":8192,"createdAt":"2026-10-10T15:04:05.123456789+02:00"},{"filename":"x.img.incomplete","size":1,"createdAt":"2026-10-10T13:04:05Z"}]}"#
        let files = try JSONDecoder().decode(StorageFiles.self, from: Data(json.utf8)).files
        XCTAssertEqual(files.map(\.filename), ["debian.iso", "x.img.incomplete"])
        XCTAssertNotNil(files[0].createdAt)
        XCTAssertNotNil(files[1].createdAt)
        XCTAssertTrue(files[1].isIncomplete)
    }

    func testCertificatePinChecksTheChainsAuthority() {
        let leaf = Data("leaf".utf8), ca = Data("device-ca".utf8)
        // Chains here stand for what SecTrust built, i.e. already linked by
        // signatures (a forged leaf yields a chain without the CA).
        XCTAssertTrue(CertificatePin.accepts(chain: [leaf, ca], pin: nil), "first use")
        XCTAssertTrue(CertificatePin.accepts(chain: [Data("other-leaf".utf8), ca], pin: CertificatePin.fingerprint(ca)))
        XCTAssertFalse(CertificatePin.accepts(chain: [Data("forged-leaf".utf8)], pin: CertificatePin.fingerprint(ca)))
        XCTAssertFalse(CertificatePin.accepts(chain: [leaf, Data("evil-ca".utf8)], pin: CertificatePin.fingerprint(ca)))
        XCTAssertFalse(CertificatePin.accepts(chain: [], pin: nil))
        // Same algorithm as the engine (sha256 hex).
        XCTAssertEqual(CertificatePin.fingerprint(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSerialSettingsRoundTripOneField() throws {
        var settings = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"BaudRate":9600,"Parity":"none","Buttons":[]}"#.utf8))
        settings["BaudRate"] = .number(115200)
        XCTAssertEqual(settings["BaudRate"]?.numberValue, 115200)
        XCTAssertEqual(settings["Parity"]?.stringValue, "none")
    }
}

final class RemoteDisplayTests: XCTestCase {
    /// JetKVM 0.5.9's default EDID, as getEDID returns it.
    static let defaultEDID = "00FFFFFFFFFFFF0028B4010001EEFFC0302301038047287856EE91A3544C99260F5054000000D1C081C0318001010101010101010101023A801871382D40582C4500C48E2100001E773300A050D02B2030203500122C2100001A000000FD00174C0F5111000A202020202020000000FC004A65744B564D2076310A20202001D5020322D1431004012309070783010000E200CFE40D100401E305000065030C001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000CF"

    func testSizeFollowsTheViewInWholeSteps() {
        typealias S = RemoteDisplay.Size
        XCTAssertEqual(RemoteDisplay.size(fitting: 1504, 944), S(width: 1504, height: 944))
        XCTAssertEqual(RemoteDisplay.size(fitting: 1511, 947), S(width: 1504, height: 944))
        // Beyond the limits: the closest size of the same shape.
        XCTAssertEqual(RemoteDisplay.size(fitting: 2400, 1300), S(width: 1920, height: 1040))
        XCTAssertEqual(RemoteDisplay.size(fitting: 500, 300), S(width: 656, height: 400))
        XCTAssertEqual(RemoteDisplay.size(fitting: 3000, 300), S(width: 1920, height: 400))
    }

    /// Timings measured to stream cleanly on a JetKVM with a Mac host
    /// (width, height, h blank, v blank, v sync, pixel clock kHz).
    func testTimingsMatchTheOnesVerifiedOnTheDevice() {
        let verified = [
            (1504, 944, 1168, 27, 10, 155670), (1024, 600, 2768, 19, 10, 140830),
            (1920, 1080, 512, 31, 5, 162120), (1920, 1200, 272, 35, 6, 162430),
            (960, 540, 2640, 98, 5, 137810), (800, 500, 2200, 212, 6, 128160),
            (640, 400, 1760, 389, 6, 113620),
        ]
        for (w, h, hBlank, vBlank, vSync, clock) in verified {
            let t = RemoteDisplay.timing(for: .init(width: w, height: h))
            XCTAssertEqual([t.hBlank, t.vBlank, t.vSync, t.pixelClockKHz], [hBlank, vBlank, vSync, clock], "\(w)×\(h)")
            XCTAssertLessThanOrEqual(t.hTotal * 4, w * 15, "line at most 3.75 widths")
            XCTAssertLessThanOrEqual(t.pixelClockKHz, 165_000)
        }
    }

    func testEDIDAdvertisesOnlyTheNewModeAndKeepsTheDisplay() throws {
        let base = try XCTUnwrap(RemoteDisplay.bytes(hex: Self.defaultEDID))
        let edid = try RemoteDisplay.edid(base, advertising: .init(width: 1504, height: 944))
        // The exact bytes the device and a Mac host accepted.
        XCTAssertEqual(RemoteDisplay.hex(edid), "00FFFFFFFFFFFF0028B4010001EEFFC0302301038028197856EE91A3544C99260F505400000001010101010101010101010101010101CF3CE09054B01B3030203A008EFA1000001A000000FD00174C0F5111000A202020202020000000FC004A65744B564D2076310A202020000000100000000000000000000000000000016102031ED02309070783010000E200CFE40D100401E305000065030C001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002C")
        XCTAssertEqual(RemoteDisplay.preferredSize(edid), .init(width: 1504, height: 944))
        XCTAssertEqual(Array(edid[8..<18]), Array(base[8..<18]), "same vendor, product, serial, date")
        for block in 0..<2 {
            XCTAssertEqual(edid[block * 128 ..< block * 128 + 128].reduce(0) { ($0 + Int($1)) & 0xFF }, 0)
        }
        // Applying it again (the next resize starts from the device's EDID)
        // only changes the timing.
        XCTAssertEqual(try RemoteDisplay.edid(edid, advertising: .init(width: 1504, height: 944)), edid)
        let other = try RemoteDisplay.edid(edid, advertising: .init(width: 1920, height: 1200))
        XCTAssertEqual(try RemoteDisplay.edid(base, advertising: .init(width: 1920, height: 1200)), other)
        XCTAssertThrowsError(try RemoteDisplay.edid([1, 2, 3], advertising: .init(width: 1504, height: 944)))
    }
}
